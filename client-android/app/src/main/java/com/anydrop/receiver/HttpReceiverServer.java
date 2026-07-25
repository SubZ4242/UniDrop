package com.unidrop.receiver;

import android.content.Context;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public final class HttpReceiverServer {
    private static final String TAG = "UniDropHttp";
    private static final int MAX_HEADER_BYTES = 64 * 1024;
    private static final int UPLOAD_IDLE_TIMEOUT_MS = 20_000;
    private final Context context;
    private final int port;
    private final ReceiverService.StatusListener listener;
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private volatile boolean running;
    private ServerSocket serverSocket;
    private Thread acceptThread;

    public HttpReceiverServer(Context context, int port, ReceiverService.StatusListener listener) {
        this.context = context.getApplicationContext();
        this.port = port;
        this.listener = listener;
    }

    public void start() {
        if (running) {
            return;
        }
        running = true;
        acceptThread = new Thread(this::acceptLoop, "unidrop-http-accept");
        acceptThread.start();
    }

    public void stop() {
        running = false;
        closeQuietly(serverSocket);
        workers.shutdownNow();
        try {
            workers.awaitTermination(2, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }

    private void acceptLoop() {
        try (ServerSocket socket = new ServerSocket()) {
            socket.setReuseAddress(true);
            socket.bind(new InetSocketAddress(InetAddress.getByName("0.0.0.0"), port));
            serverSocket = socket;
            listener.onStatus(new ReceiverService.ServerStatus(true, "läuft auf Port " + port), Collections.emptyList());
            while (running) {
                try {
                    Socket client = socket.accept();
                    client.setSoTimeout(UPLOAD_IDLE_TIMEOUT_MS);
                    workers.submit(() -> handleClient(client));
                } catch (IOException exc) {
                    if (running) {
                        Log.w(TAG, "accept failed", exc);
                    }
                }
            }
        } catch (IOException exc) {
            listener.onStatus(new ReceiverService.ServerStatus(false, "Port " + port + " nicht verfügbar"), Collections.emptyList());
            Log.e(TAG, "server failed", exc);
        } finally {
            running = false;
            listener.onStatus(new ReceiverService.ServerStatus(false, "gestoppt"), Collections.emptyList());
        }
    }

    private void handleClient(Socket client) {
        try (Socket socket = client) {
            InputStream input = new BufferedInputStream(socket.getInputStream());
            OutputStream output = new BufferedOutputStream(socket.getOutputStream());
            Request request = readRequest(input);
            if (request == null) {
                writeResponse(output, 400, "text/plain", "Bad Request".getBytes(StandardCharsets.UTF_8));
                return;
            }
            if ("GET".equals(request.method) && "/health".equals(request.path)) {
                byte[] body = (
                    "{\"status\":\"ok\",\"app\":\"UniDrop\",\"platform\":\"android\",\"receiver\":\"" + jsonEscape(receiverName()) + "\",\"version\":\"0.1.0\",\"outputDirectory\":\"Downloads/UniDrop\"}"
                ).getBytes(StandardCharsets.UTF_8);
                writeResponse(output, 200, "application/json", body);
                return;
            }
            if ("POST".equals(request.method) && "/api/transfers/archive".equals(request.path)) {
                handleUpload(input, output, request);
                return;
            }
            writeResponse(output, 404, "text/plain", "Not Found".getBytes(StandardCharsets.UTF_8));
        } catch (SocketTimeoutException exc) {
            Log.w(TAG, "client timed out", exc);
        } catch (Exception exc) {
            Log.e(TAG, "client failed", exc);
        }
    }

    private void handleUpload(InputStream input, OutputStream output, Request request) throws IOException {
        String contentType = normalizedContentType(request.headers.get("content-type"));
        if (!"application/x-cpio".equals(contentType) && !"application/x-dvzip".equals(contentType)) {
            writeResponse(output, 415, "application/json", jsonError("unsupported_media_type").getBytes(StandardCharsets.UTF_8));
            return;
        }
        long contentLength = parseContentLength(request.headers.get("content-length"));
        if (contentLength < 0) {
            writeResponse(output, 411, "application/json", jsonError("content_length_required").getBytes(StandardCharsets.UTF_8));
            return;
        }

        File archive = new File(context.getCacheDir(), "unidrop-upload-" + UUID.randomUUID() + ".archive");
        try {
            copyExactly(input, archive, contentLength);
            List<SavedFile> files = ArchiveExtractor.extract(context, archive, contentType);
            listener.onStatus(new ReceiverService.ServerStatus(true, files.size() + " Datei(en) gespeichert"), files);
            writeResponse(output, 200, "application/json", savedJson(files).getBytes(StandardCharsets.UTF_8));
        } catch (Exception exc) {
            Log.e(TAG, "upload rejected", exc);
            writeResponse(output, 400, "application/json", jsonError("invalid_archive", exc.getClass().getSimpleName() + ": " + exc.getMessage()).getBytes(StandardCharsets.UTF_8));
        } finally {
            if (!archive.delete() && archive.exists()) {
                Log.w(TAG, "could not delete temp archive " + archive);
            }
        }
    }

    private Request readRequest(InputStream input) throws IOException {
        ByteArrayOutputStream headerBuffer = new ByteArrayOutputStream();
        int previous3 = -1;
        int previous2 = -1;
        int previous1 = -1;
        while (headerBuffer.size() < MAX_HEADER_BYTES) {
            int current = input.read();
            if (current < 0) {
                return null;
            }
            headerBuffer.write(current);
            if (previous3 == '\r' && previous2 == '\n' && previous1 == '\r' && current == '\n') {
                break;
            }
            previous3 = previous2;
            previous2 = previous1;
            previous1 = current;
        }
        String headersText = headerBuffer.toString(StandardCharsets.ISO_8859_1.name());
        String[] lines = headersText.split("\\r?\\n");
        if (lines.length == 0) {
            return null;
        }
        String[] requestLine = lines[0].split(" ", 3);
        if (requestLine.length < 2) {
            return null;
        }
        Map<String, String> headers = new LinkedHashMap<>();
        for (int i = 1; i < lines.length; i++) {
            int colon = lines[i].indexOf(':');
            if (colon <= 0) {
                continue;
            }
            headers.put(
                lines[i].substring(0, colon).trim().toLowerCase(Locale.ROOT),
                lines[i].substring(colon + 1).trim()
            );
        }
        return new Request(requestLine[0], requestLine[1], headers);
    }

    private void writeResponse(OutputStream output, int status, String contentType, byte[] body) throws IOException {
        String reason = switch (status) {
            case 200 -> "OK";
            case 400 -> "Bad Request";
            case 404 -> "Not Found";
            case 411 -> "Length Required";
            case 415 -> "Unsupported Media Type";
            default -> "Error";
        };
        byte[] header = (
            "HTTP/1.1 " + status + " " + reason + "\r\n"
                + "Content-Type: " + contentType + "\r\n"
                + "Content-Length: " + body.length + "\r\n"
                + "Connection: close\r\n"
                + "\r\n"
        ).getBytes(StandardCharsets.ISO_8859_1);
        output.write(header);
        output.write(body);
        output.flush();
    }

    private void copyExactly(InputStream input, File outputFile, long bytes) throws IOException {
        byte[] buffer = new byte[128 * 1024];
        long remaining = bytes;
        try (OutputStream output = new FileOutputStream(outputFile)) {
            while (remaining > 0) {
                int read = input.read(buffer, 0, (int) Math.min(buffer.length, remaining));
                if (read < 0) {
                    throw new IOException("truncated upload body");
                }
                output.write(buffer, 0, read);
                remaining -= read;
            }
        }
    }

    private long parseContentLength(String value) {
        if (value == null) {
            return -1;
        }
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException exc) {
            return -1;
        }
    }

    private String normalizedContentType(String value) {
        if (value == null) {
            return "";
        }
        return value.split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
    }

    private String jsonError(String error) {
        return "{\"status\":\"failed\",\"error\":\"" + error + "\"}";
    }

    private String jsonError(String error, String message) {
        return "{\"status\":\"failed\",\"error\":\"" + jsonEscape(error) + "\",\"message\":\"" + jsonEscape(message == null ? "" : message) + "\"}";
    }

    private String receiverName() {
        String configuredName = Settings.Global.getString(context.getContentResolver(), "device_name");
        if (configuredName != null && !configuredName.trim().isEmpty()) {
            return configuredName.trim();
        }
        String model = Build.MODEL == null ? "" : Build.MODEL.trim();
        if (model.toUpperCase(Locale.ROOT).startsWith("SM-G97")) {
            return "Galaxy S10";
        }
        if (model.isEmpty()) {
            return "Android";
        }
        return model.replace("\"", "");
    }

    private String jsonEscape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private String savedJson(List<SavedFile> files) {
        StringBuilder builder = new StringBuilder("{\"status\":\"saved\",\"files\":[");
        for (int i = 0; i < files.size(); i++) {
            if (i > 0) {
                builder.append(',');
            }
            builder.append('"').append(jsonEscape(files.get(i).displayPath)).append('"');
        }
        return builder.append("]}").toString();
    }

    private void closeQuietly(ServerSocket socket) {
        if (socket == null) {
            return;
        }
        try {
            socket.close();
        } catch (IOException ignored) {
        }
    }

    private static final class Request {
        final String method;
        final String path;
        final Map<String, String> headers;

        Request(String method, String path, Map<String, String> headers) {
            this.method = method;
            this.path = path;
            this.headers = headers;
        }
    }
}
