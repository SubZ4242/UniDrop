using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Microsoft.Win32;

ApplicationConfiguration.Initialize();
Application.Run(new WinDropTrayContext());

sealed class WinDropTrayContext : ApplicationContext
{
    private const string AppName = "UniDrop";
    private readonly Icon appIcon = IconFactory.CreateDropIcon(64);
    private readonly SynchronizationContext uiContext;
    private readonly int uiThreadId;
    private readonly NotifyIcon notifyIcon;
    private readonly SettingsForm form;
    private readonly ToolStripMenuItem toggleMenuItem;
    private readonly System.Windows.Forms.Timer statusTimer;
    private readonly System.Windows.Forms.Timer openFolderTimer;
    private FileSystemWatcher? outputWatcher;
    private Process? receiverProcess;
    private string? pendingOpenPath;
    private int pendingRevealAttempts;

    public WinDropTrayContext()
    {
        uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        uiThreadId = Environment.CurrentManagedThreadId;
        form = new SettingsForm(this);
        toggleMenuItem = new ToolStripMenuItem("Empfang einschalten", null, (_, _) => ToggleReceiver());
        notifyIcon = new NotifyIcon
        {
            Icon = appIcon,
            Text = AppName,
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };
        notifyIcon.DoubleClick += (_, _) => ShowSettings();

        statusTimer = new System.Windows.Forms.Timer { Interval = 3000 };
        statusTimer.Tick += (_, _) => UpdateStatusViews();
        statusTimer.Start();

        openFolderTimer = new System.Windows.Forms.Timer { Interval = 900 };
        openFolderTimer.Tick += (_, _) =>
        {
            openFolderTimer.Stop();
            if (!string.IsNullOrWhiteSpace(pendingOpenPath))
            {
                if (RevealPathInExplorer(pendingOpenPath) || pendingRevealAttempts >= 8)
                {
                    pendingOpenPath = null;
                    pendingRevealAttempts = 0;
                }
                else
                {
                    pendingRevealAttempts++;
                    openFolderTimer.Start();
                }
            }
        };

        ConfigureOutputWatcher();
        if (WinDropSettings.Load().AutoReceive)
        {
            StartReceiver();
        }
        UpdateStatusViews();
    }

    public bool IsReceiving => IsOwnedProcessRunning || ReceiverResponds(WinDropSettings.Load().ListenUrl);

    private bool IsOwnedProcessRunning => receiverProcess is { HasExited: false };

    public void ShowSettings()
    {
        form.LoadSettings();
        form.Show();
        form.Activate();
    }

    public void ToggleReceiver()
    {
        if (IsReceiving)
        {
            StopReceiver();
        }
        else
        {
            StartReceiver();
        }
    }

    public void StartReceiver()
    {
        var settings = WinDropSettings.Load();
        ConfigureOutputWatcher();
        if (IsOwnedProcessRunning || ReceiverResponds(settings.ListenUrl))
        {
            UpdateStatusViews();
            return;
        }

        Directory.CreateDirectory(settings.OutputDirectory);
        var startInfo = new ProcessStartInfo
        {
            FileName = LocateReceiver(),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("--listen");
        startInfo.ArgumentList.Add(settings.ListenUrl);
        startInfo.ArgumentList.Add("--out");
        startInfo.ArgumentList.Add(settings.OutputDirectory);

        receiverProcess = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true
        };
        receiverProcess.Exited += (_, _) => UpdateStatusViews();
        receiverProcess.OutputDataReceived += (_, eventArgs) => AppendReceiverLog(eventArgs.Data);
        receiverProcess.ErrorDataReceived += (_, eventArgs) => AppendReceiverLog(eventArgs.Data);
        receiverProcess.Start();
        receiverProcess.BeginOutputReadLine();
        receiverProcess.BeginErrorReadLine();
        UpdateStatusViews();
    }

    public void StopReceiver()
    {
        if (IsOwnedProcessRunning)
        {
            receiverProcess!.Kill(entireProcessTree: true);
            receiverProcess.WaitForExit(3000);
        }
        else
        {
            foreach (var process in Process.GetProcessesByName("WinDropReceiver"))
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(3000);
            }
        }
        UpdateStatusViews();
    }

    public void SetAutostart(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", writable: true)
            ?? Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", writable: true);
        if (enabled)
        {
            key.SetValue("UniDropTray", Quote(Application.ExecutablePath));
        }
        else
        {
            key.DeleteValue("UniDropTray", throwOnMissingValue: false);
        }
    }

    public bool IsAutostartEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return key?.GetValue("UniDropTray") is string value
            && value.Contains(Application.ExecutablePath, StringComparison.OrdinalIgnoreCase);
    }

    public void ConfigureOutputWatcher()
    {
        outputWatcher?.Dispose();
        outputWatcher = null;

        var settings = WinDropSettings.Load();
        Directory.CreateDirectory(settings.OutputDirectory);
        outputWatcher = new FileSystemWatcher(settings.OutputDirectory)
        {
            IncludeSubdirectories = false,
            EnableRaisingEvents = true,
        };
        outputWatcher.Created += (_, eventArgs) => QueueAutoOpenFolder(eventArgs.FullPath);
        outputWatcher.Renamed += (_, eventArgs) => QueueAutoOpenFolder(eventArgs.FullPath);
    }

    public void UpdateStatusViews()
    {
        if (form.IsHandleCreated && form.InvokeRequired)
        {
            form.BeginInvoke(UpdateStatusViews);
            return;
        }

        var receiving = IsReceiving;
        notifyIcon.Text = receiving ? "UniDrop: empfangsbereit" : "UniDrop: aus";
        toggleMenuItem.Text = receiving ? "Empfang ausschalten" : "Empfang einschalten";
        form.SetStatus(receiving);
    }

    protected override void ExitThreadCore()
    {
        statusTimer.Stop();
        openFolderTimer.Stop();
        outputWatcher?.Dispose();
        StopReceiver();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        appIcon.Dispose();
        base.ExitThreadCore();
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Oeffnen", null, (_, _) => ShowSettings());
        menu.Items.Add(toggleMenuItem);
        menu.Items.Add("Ordner oeffnen", null, (_, _) => OpenFolder(WinDropSettings.Load().OutputDirectory));
        menu.Items.Add("Beenden", null, (_, _) => ExitThread());
        return menu;
    }

    private void QueueAutoOpenFolder(string changedPath)
    {
        if (Environment.CurrentManagedThreadId != uiThreadId)
        {
            uiContext.Post(_ => QueueAutoOpenFolder(changedPath), null);
            return;
        }

        var settings = WinDropSettings.Load();
        if (!settings.AutoOpenFolder || Directory.Exists(changedPath))
        {
            return;
        }

        pendingOpenPath = Path.GetFullPath(changedPath);
        pendingRevealAttempts = 0;
        openFolderTimer.Stop();
        openFolderTimer.Start();

        notifyIcon.BalloonTipTitle = AppName;
        notifyIcon.BalloonTipText = $"Empfangen: {Path.GetFileName(changedPath)}";
        notifyIcon.ShowBalloonTip(1800);
    }

    private static void OpenFolder(string folder)
    {
        Directory.CreateDirectory(folder);
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            ArgumentList = { folder },
            UseShellExecute = true,
        });
    }

    private static bool RevealPathInExplorer(string path)
    {
        if (File.Exists(path))
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"/select,\"{path}\"",
                UseShellExecute = true,
            });
            return true;
        }

        var folder = Directory.Exists(path) ? path : Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(folder))
        {
            OpenFolder(folder);
            return true;
        }
        return false;
    }

    private static bool ReceiverResponds(string listenUrl)
    {
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromMilliseconds(700) };
            using var response = client.GetAsync(listenUrl.TrimEnd('/') + "/health").GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode)
            {
                return false;
            }
            var body = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            return body.Contains("UniDrop", StringComparison.OrdinalIgnoreCase)
                || body.Contains("WinDrop Windows Receiver", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    private static string LocateReceiver()
    {
        var appDir = AppContext.BaseDirectory;
        var bundled = Path.Combine(appDir, "WinDropReceiver.exe");
        if (File.Exists(bundled))
        {
            return bundled;
        }

        var siblingPublish = Path.GetFullPath(Path.Combine(appDir, "..", "receiver", "WinDropReceiver.exe"));
        if (File.Exists(siblingPublish))
        {
            return siblingPublish;
        }

        var repoReceiver = Path.GetFullPath(Path.Combine(
            appDir,
            "..", "..", "..", "..", "..", "WinDropReceiver", "bin", "Debug", "net8.0", "WinDropReceiver.exe"
        ));
        if (File.Exists(repoReceiver))
        {
            return repoReceiver;
        }

        throw new FileNotFoundException("WinDropReceiver.exe wurde nicht gefunden. Bitte zuerst publish-windows.ps1 ausfuehren.");
    }

    private static string Quote(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";

    private static void AppendReceiverLog(string? line)
    {
        if (string.IsNullOrEmpty(line))
        {
            return;
        }

        var logPath = Path.Combine(WinDropSettings.DirectoryPath, "receiver.log");
        Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
        File.AppendAllText(logPath, $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss}] {line}{Environment.NewLine}");
    }
}

sealed class SettingsForm : Form
{
    private readonly WinDropTrayContext context;
    private readonly RoundButton receiveButton = new();
    private readonly TextBox gatewayUrl = new();
    private readonly TextBox listenUrl = new();
    private readonly TextBox outputDirectory = new();
    private readonly CheckBox autostart = new() { Text = "Mit Windows starten", AutoSize = true };
    private readonly CheckBox autoReceive = new() { Text = "Auto-Empfang", AutoSize = true };
    private readonly CheckBox autoOpenFolder = new() { Text = "Ordner nach Empfang oeffnen", AutoSize = true };
    private readonly Label status = new();
    private readonly Label endpoint = new();
    private readonly DropMark dropMark = new();

    public SettingsForm(WinDropTrayContext context)
    {
        this.context = context;
        Text = "UniDrop";
        Font = Theme.BodyFont;
        BackColor = Theme.Surface;
        MinimumSize = new Size(680, 430);
        Size = WinDropSettings.Load().WindowSize;
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = true;
        ResizeEnd += (_, _) => SaveWindowSize();
        FormClosing += (_, eventArgs) =>
        {
            SaveWindowSize();
            eventArgs.Cancel = true;
            Hide();
        };

        Controls.Add(BuildLayout());
        LoadSettings();
    }

    public void LoadSettings()
    {
        var settings = WinDropSettings.Load();
        gatewayUrl.Text = settings.GatewayUrl;
        listenUrl.Text = settings.ListenUrl;
        outputDirectory.Text = settings.OutputDirectory;
        autoReceive.Checked = settings.AutoReceive;
        autoOpenFolder.Checked = settings.AutoOpenFolder;
        autostart.Checked = context.IsAutostartEnabled();
        endpoint.Text = settings.ListenUrl;
        SetStatus(context.IsReceiving);
        if (string.IsNullOrWhiteSpace(settings.GatewayUrl))
        {
            BeginInvoke(new Action(() => DiscoverMacGateway(showMessage: false)));
        }
    }

    public void SetStatus(bool receiving)
    {
        receiveButton.SetReceiving(receiving);
        dropMark.SetReceiving(receiving);
        status.Text = receiving ? "Empfangsbereit" : "Ausgeschaltet";
        status.ForeColor = receiving ? Theme.Green : Theme.Red;
    }

    private Control BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(24),
            ColumnCount = 2,
            RowCount = 2,
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 92));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var header = new Panel { Dock = DockStyle.Fill };
        dropMark.Location = new Point(0, 8);
        header.Controls.Add(dropMark);
        header.Controls.Add(new Label
        {
            Text = "UniDrop",
            AutoSize = true,
            Font = Theme.DisplayFont,
            ForeColor = Theme.Text,
            Location = new Point(56, 4),
        });
        header.Controls.Add(new Label
        {
            Text = "AirDrop-Empfang ueber deinen UniDrop-Mac-Gateway",
            AutoSize = true,
            Font = Theme.BodyFont,
            ForeColor = Theme.Muted,
            Location = new Point(59, 47),
        });
        root.Controls.Add(header, 0, 0);

        var statusPanel = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Surface };
        status.AutoSize = true;
        status.Font = Theme.StatusFont;
        status.Location = new Point(16, 16);
        endpoint.AutoSize = false;
        endpoint.Width = 160;
        endpoint.Height = 38;
        endpoint.Font = Theme.SmallFont;
        endpoint.ForeColor = Theme.Muted;
        endpoint.Location = new Point(16, 43);
        statusPanel.Controls.Add(status);
        statusPanel.Controls.Add(endpoint);
        root.Controls.Add(statusPanel, 1, 0);

        var settingsCard = new RoundedPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.White,
            Padding = new Padding(22),
        };
        settingsCard.Controls.Add(BuildSettingsGrid());
        root.Controls.Add(settingsCard, 0, 1);

        var actionCard = new RoundedPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Color.White,
            Padding = new Padding(18),
        };
        actionCard.Controls.Add(BuildActionPanel());
        root.Controls.Add(actionCard, 1, 1);
        return root;
    }

    private Control BuildSettingsGrid()
    {
        var grid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 8,
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 120));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        grid.Controls.Add(new Label
        {
            Text = "Einstellungen",
            AutoSize = true,
            Font = Theme.SectionFont,
            ForeColor = Theme.Text,
        }, 0, 0);
        grid.SetColumnSpan(grid.Controls[^1], 2);

        AddGatewayField(grid, 1, "Mac Gateway", gatewayUrl);
        AddField(grid, 2, "Listen URL", listenUrl);
        AddFolderField(grid, 3, "Zielordner", outputDirectory);
        grid.Controls.Add(autostart, 1, 4);
        grid.Controls.Add(autoReceive, 1, 5);
        grid.Controls.Add(autoOpenFolder, 1, 6);

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight };
        buttons.Controls.Add(ModernButton("Speichern", (_, _) => Save()));
        buttons.Controls.Add(ModernButton("Ordner oeffnen", (_, _) => OpenOutputFolder()));
        grid.Controls.Add(buttons, 1, 7);
        return grid;
    }

    private Control BuildActionPanel()
    {
        var panel = new Panel { Dock = DockStyle.Fill };
        receiveButton.Location = new Point(31, 24);
        receiveButton.Click += (_, _) =>
        {
            Save(applyAutoReceive: false);
            context.ToggleReceiver();
            context.UpdateStatusViews();
        };
        panel.Resize += (_, _) =>
        {
            receiveButton.Left = Math.Max(0, (panel.ClientSize.Width - receiveButton.Width) / 2);
            receiveButton.Top = 26;
        };
        panel.Controls.Add(receiveButton);
        panel.Controls.Add(new Label
        {
            Text = "Empfang",
            AutoSize = false,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = Theme.SectionFont,
            ForeColor = Theme.Text,
            Location = new Point(0, 156),
            Width = 150,
            Height = 28,
        });
        panel.Controls.Add(new Label
        {
            Text = "Ein Klick schaltet den Windows-Empfang um.",
            AutoSize = false,
            TextAlign = ContentAlignment.TopCenter,
            Font = Theme.SmallFont,
            ForeColor = Theme.Muted,
            Location = new Point(0, 187),
            Width = 150,
            Height = 62,
        });
        return panel;
    }

    private static void AddField(TableLayoutPanel grid, int row, string labelText, TextBox textBox)
    {
        textBox.Dock = DockStyle.Fill;
        textBox.BorderStyle = BorderStyle.FixedSingle;
        textBox.Margin = new Padding(0, 3, 0, 9);
        grid.Controls.Add(new Label
        {
            Text = labelText,
            AutoSize = true,
            ForeColor = Theme.Muted,
            Margin = new Padding(0, 7, 0, 0),
        }, 0, row);
        grid.Controls.Add(textBox, 1, row);
    }

    private void AddFolderField(TableLayoutPanel grid, int row, string labelText, TextBox textBox)
    {
        textBox.Dock = DockStyle.Fill;
        textBox.BorderStyle = BorderStyle.FixedSingle;
        textBox.Margin = new Padding(0, 3, 8, 9);
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            Margin = new Padding(0),
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        var browse = ModernButton("Browse", (_, _) => BrowseOutputFolder());
        browse.Dock = DockStyle.Fill;
        browse.Margin = new Padding(0, 3, 0, 9);
        panel.Controls.Add(textBox, 0, 0);
        panel.Controls.Add(browse, 1, 0);
        grid.Controls.Add(new Label
        {
            Text = labelText,
            AutoSize = true,
            ForeColor = Theme.Muted,
            Margin = new Padding(0, 7, 0, 0),
        }, 0, row);
        grid.Controls.Add(panel, 1, row);
    }

    private void AddGatewayField(TableLayoutPanel grid, int row, string labelText, TextBox textBox)
    {
        textBox.Dock = DockStyle.Fill;
        textBox.BorderStyle = BorderStyle.FixedSingle;
        textBox.Margin = new Padding(0, 3, 8, 9);
        textBox.PlaceholderText = "auto";
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            Margin = new Padding(0),
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        var discover = ModernButton("Mac suchen", (_, _) => DiscoverMacGateway());
        discover.Dock = DockStyle.Fill;
        discover.Margin = new Padding(0, 3, 0, 9);
        panel.Controls.Add(textBox, 0, 0);
        panel.Controls.Add(discover, 1, 0);
        grid.Controls.Add(new Label
        {
            Text = labelText,
            AutoSize = true,
            ForeColor = Theme.Muted,
            Margin = new Padding(0, 7, 0, 0),
        }, 0, row);
        grid.Controls.Add(panel, 1, row);
    }

    private static Button ModernButton(string text, EventHandler handler)
    {
        var button = new Button
        {
            Text = text,
            AutoSize = true,
            Height = 34,
            FlatStyle = FlatStyle.Flat,
            BackColor = Theme.Blue,
            ForeColor = Color.White,
            Margin = new Padding(0, 4, 10, 0),
        };
        button.FlatAppearance.BorderSize = 0;
        button.Click += handler;
        return button;
    }

    private void Save(bool applyAutoReceive = true)
    {
        var settings = new WinDropSettings(
            gatewayUrl.Text.Trim(),
            listenUrl.Text.Trim(),
            outputDirectory.Text.Trim(),
            autoReceive.Checked,
            autoOpenFolder.Checked,
            Size
        );
        settings.Save();
        context.SetAutostart(autostart.Checked);
        context.ConfigureOutputWatcher();
        endpoint.Text = settings.ListenUrl;
        if (applyAutoReceive && settings.AutoReceive)
        {
            context.StartReceiver();
        }
        context.UpdateStatusViews();
    }

    private void OpenOutputFolder()
    {
        var folder = outputDirectory.Text.Trim();
        Directory.CreateDirectory(folder);
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            ArgumentList = { folder },
            UseShellExecute = true,
        });
    }

    private void BrowseOutputFolder()
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = "UniDrop-Zielordner auswählen",
            UseDescriptionForTitle = true,
            SelectedPath = Directory.Exists(outputDirectory.Text.Trim())
                ? outputDirectory.Text.Trim()
                : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            outputDirectory.Text = dialog.SelectedPath;
        }
    }

    private async void DiscoverMacGateway(bool showMessage = true)
    {
        var hint = gatewayUrl.Text.Trim();
        gatewayUrl.Text = "suche...";
        var discovered = await Task.Run(() => MacGatewayDiscovery.Find(hint));
        if (discovered is null)
        {
            gatewayUrl.Text = "";
            if (showMessage)
            {
                MessageBox.Show(this, "Kein UniDrop-Mac-Gateway im lokalen Netz gefunden.", "UniDrop", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            return;
        }
        gatewayUrl.Text = discovered;
        Save(applyAutoReceive: false);
    }

    private void SaveWindowSize()
    {
        if (WindowState != FormWindowState.Normal)
        {
            return;
        }

        WinDropSettings.Load().WithWindowSize(Size).Save();
    }
}

sealed record WinDropSettings(
    string GatewayUrl,
    string ListenUrl,
    string OutputDirectory,
    bool AutoReceive,
    bool AutoOpenFolder,
    Size WindowSize
)
{
    public static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "UniDrop"
    );
    private static readonly string FilePath = Path.Combine(DirectoryPath, "settings.txt");

    public static WinDropSettings Load()
    {
        var listen = DefaultListenUrl();
        var gateway = "";
        var output = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "UniDrop");
        var autoReceive = true;
        var autoOpenFolder = false;
        var windowSize = new Size(720, 460);
        if (File.Exists(FilePath))
        {
            foreach (var line in File.ReadAllLines(FilePath))
            {
                if (line.StartsWith("listen=", StringComparison.OrdinalIgnoreCase))
                {
                    listen = line["listen=".Length..];
                }
                else if (line.StartsWith("gateway=", StringComparison.OrdinalIgnoreCase))
                {
                    gateway = line["gateway=".Length..];
                }
                else if (line.StartsWith("output=", StringComparison.OrdinalIgnoreCase))
                {
                    output = line["output=".Length..];
                }
                else if (line.StartsWith("auto_receive=", StringComparison.OrdinalIgnoreCase))
                {
                    autoReceive = bool.TryParse(line["auto_receive=".Length..], out var parsed) && parsed;
                }
                else if (line.StartsWith("auto_open_folder=", StringComparison.OrdinalIgnoreCase))
                {
                    autoOpenFolder = bool.TryParse(line["auto_open_folder=".Length..], out var parsed) && parsed;
                }
                else if (line.StartsWith("window_width=", StringComparison.OrdinalIgnoreCase)
                    && int.TryParse(line["window_width=".Length..], out var width))
                {
                    windowSize.Width = Math.Max(680, width);
                }
                else if (line.StartsWith("window_height=", StringComparison.OrdinalIgnoreCase)
                    && int.TryParse(line["window_height=".Length..], out var height))
                {
                    windowSize.Height = Math.Max(430, height);
                }
            }
        }

        if (listen.Contains("127.0.0.1", StringComparison.OrdinalIgnoreCase)
            || listen.Contains("localhost", StringComparison.OrdinalIgnoreCase))
        {
            listen = DefaultListenUrl();
        }

        return new WinDropSettings(gateway, listen, output, autoReceive, autoOpenFolder, windowSize);
    }

    public WinDropSettings WithWindowSize(Size windowSize) => this with { WindowSize = windowSize };

    public void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllLines(FilePath, [
            "gateway=" + GatewayUrl,
            "listen=" + ListenUrl,
            "output=" + OutputDirectory,
            "auto_receive=" + AutoReceive,
            "auto_open_folder=" + AutoOpenFolder,
            "window_width=" + WindowSize.Width,
            "window_height=" + WindowSize.Height
        ]);
    }

    private static string DefaultListenUrl()
    {
        return $"http://{FindLanAddress() ?? "0.0.0.0"}:8873";
    }

    public static string? FindLanAddress()
    {
        foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (networkInterface.OperationalStatus != OperationalStatus.Up
                || networkInterface.NetworkInterfaceType == NetworkInterfaceType.Loopback
                || networkInterface.Description.Contains("Tailscale", StringComparison.OrdinalIgnoreCase)
                || networkInterface.Description.Contains("Nord", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            foreach (var address in networkInterface.GetIPProperties().UnicastAddresses)
            {
                if (address.Address.AddressFamily == AddressFamily.InterNetwork
                    && !IPAddress.IsLoopback(address.Address)
                    && IsPrivateAddress(address.Address))
                {
                    return address.Address.ToString();
                }
            }
        }
        return null;
    }

    private static bool IsPrivateAddress(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes[0] == 10
            || bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31
            || bytes[0] == 192 && bytes[1] == 168;
    }
}

static class MacGatewayDiscovery
{
    public static string? Find(string hint)
    {
        var ownIp = WinDropSettings.FindLanAddress();
        if (string.IsNullOrWhiteSpace(ownIp))
        {
            return null;
        }
        var lastDot = ownIp.LastIndexOf('.');
        if (lastDot <= 0)
        {
            return null;
        }
        var prefix = ownIp[..(lastDot + 1)];
        var port = ExtractPort(hint);
        string? found = null;
        object gate = new();

        Parallel.ForEach(
            Enumerable.Range(1, 254),
            new ParallelOptions { MaxDegreeOfParallelism = 48 },
            (host, state) =>
            {
                if (Volatile.Read(ref found) is not null)
                {
                    state.Stop();
                    return;
                }
                var ip = prefix + host;
                if (ip == ownIp)
                {
                    return;
                }
                if (!IsUniDropGateway(ip, port))
                {
                    return;
                }
                lock (gate)
                {
                    found ??= $"http://{ip}:{port}/gateway";
                }
                state.Stop();
            }
        );
        return found;
    }

    private static int ExtractPort(string value)
    {
        if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Port > 0)
        {
            return uri.Port;
        }
        return 8873;
    }

    private static bool IsUniDropGateway(string ip, int port)
    {
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromMilliseconds(450) };
            var body = client.GetStringAsync($"http://{ip}:{port}/gateway").GetAwaiter().GetResult();
            return body.Contains("\"app\":\"UniDrop\"", StringComparison.OrdinalIgnoreCase)
                && body.Contains("\"role\":\"mac-gateway\"", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}

sealed class RoundButton : Button
{
    private bool receiving;
    private bool hovered;
    private bool pressed;

    public RoundButton()
    {
        Width = 118;
        Height = 118;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Font = Theme.ActionFont;
        ForeColor = Color.White;
        Cursor = Cursors.Hand;
        Text = "AUS";
        SetReceiving(false);
    }

    public void SetReceiving(bool isReceiving)
    {
        receiving = isReceiving;
        Text = receiving ? "AN" : "AUS";
        BackColor = receiving ? Theme.Green : Theme.Red;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs pevent)
    {
        var graphics = pevent.Graphics;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.Clear(Parent?.BackColor ?? Theme.Surface);

        var offset = pressed ? 3 : 0;
        var bodyRect = Rectangle.Inflate(ClientRectangle, -7, -7);
        bodyRect.Offset(0, offset);
        var shadowRect = bodyRect;
        shadowRect.Offset(0, pressed ? 3 : 7);

        using (var shadow = new SolidBrush(Color.FromArgb(pressed ? 32 : 58, 21, 42, 78)))
        {
            graphics.FillEllipse(shadow, shadowRect);
        }

        var top = hovered ? ControlPaint.Light(BackColor, 0.18f) : ControlPaint.Light(BackColor, 0.08f);
        var bottom = pressed ? ControlPaint.Dark(BackColor, 0.18f) : ControlPaint.Dark(BackColor, 0.06f);
        using (var brush = new LinearGradientBrush(bodyRect, top, bottom, 90f))
        {
            graphics.FillEllipse(brush, bodyRect);
        }

        using (var ring = new Pen(Color.FromArgb(pressed ? 70 : 120, Color.White), 2f))
        {
            graphics.DrawEllipse(ring, Rectangle.Inflate(bodyRect, -2, -2));
        }

        using (var shine = new SolidBrush(Color.FromArgb(hovered ? 86 : 58, Color.White)))
        {
            graphics.FillEllipse(shine, bodyRect.X + 31, bodyRect.Y + 19, 21, 13);
        }

        using (var dropPath = IconFactory.CreateDropPath(new RectangleF(bodyRect.X + 43, bodyRect.Y + 23, 26, 34)))
        using (var dropBrush = new SolidBrush(Color.FromArgb(190, Color.White)))
        {
            graphics.FillPath(dropBrush, dropPath);
        }

        var textRect = bodyRect;
        textRect.Y += 33;
        TextRenderer.DrawText(
            graphics,
            Text,
            Font,
            textRect,
            ForeColor,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter
        );
    }

    protected override void OnMouseEnter(EventArgs e)
    {
        hovered = true;
        Invalidate();
        base.OnMouseEnter(e);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        hovered = false;
        pressed = false;
        Invalidate();
        base.OnMouseLeave(e);
    }

    protected override void OnMouseDown(MouseEventArgs mevent)
    {
        if (mevent.Button == MouseButtons.Left)
        {
            pressed = true;
            Invalidate();
        }
        base.OnMouseDown(mevent);
    }

    protected override void OnMouseUp(MouseEventArgs mevent)
    {
        pressed = false;
        Invalidate();
        base.OnMouseUp(mevent);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        using var path = new GraphicsPath();
        path.AddEllipse(0, 0, Width - 1, Height - 1);
        Region = new Region(path);
    }
}

sealed class DropMark : Control
{
    private bool receiving;

    public DropMark()
    {
        Width = 42;
        Height = 42;
    }

    public void SetReceiving(bool isReceiving)
    {
        receiving = isReceiving;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = IconFactory.CreateDropPath(new RectangleF(7, 4, 28, 34));
        using var brush = new LinearGradientBrush(ClientRectangle, receiving ? Theme.Blue : Theme.Muted, receiving ? Theme.Cyan : Theme.Border, 45f);
        e.Graphics.FillPath(brush, path);
    }
}

sealed class RoundedPanel : Panel
{
    public RoundedPanel()
    {
        DoubleBuffered = true;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = RoundedRect(ClientRectangle, 14);
        using var pen = new Pen(Theme.Border);
        e.Graphics.DrawPath(pen, path);
    }

    protected override void OnResize(EventArgs eventargs)
    {
        base.OnResize(eventargs);
        using var path = RoundedRect(ClientRectangle, 14);
        Region = new Region(path);
    }

    private static GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        bounds = Rectangle.Inflate(bounds, -1, -1);
        var path = new GraphicsPath();
        var diameter = radius * 2;
        var rect = new Rectangle(bounds.X, bounds.Y, diameter, diameter);
        path.AddArc(rect, 180, 90);
        rect.X = bounds.Right - diameter - 1;
        path.AddArc(rect, 270, 90);
        rect.Y = bounds.Bottom - diameter - 1;
        path.AddArc(rect, 0, 90);
        rect.X = bounds.X;
        path.AddArc(rect, 90, 90);
        path.CloseFigure();
        return path;
    }
}

static class IconFactory
{
    public static Icon CreateDropIcon(int size)
    {
        using var bitmap = new Bitmap(size, size);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var path = CreateDropPath(new RectangleF(size * 0.24f, size * 0.12f, size * 0.52f, size * 0.72f));
            using var brush = new LinearGradientBrush(new Rectangle(0, 0, size, size), Theme.Cyan, Theme.Blue, 45f);
            graphics.FillPath(brush, path);
            using var highlight = new SolidBrush(Color.FromArgb(115, Color.White));
            graphics.FillEllipse(highlight, size * 0.42f, size * 0.27f, size * 0.12f, size * 0.18f);
        }
        return Icon.FromHandle(bitmap.GetHicon());
    }

    public static GraphicsPath CreateDropPath(RectangleF bounds)
    {
        var path = new GraphicsPath();
        var cx = bounds.X + bounds.Width / 2;
        var top = bounds.Y;
        var bottom = bounds.Bottom;
        path.AddBezier(cx, top, bounds.Right, bounds.Y + bounds.Height * 0.34f, bounds.Right, bounds.Y + bounds.Height * 0.66f, cx, bottom);
        path.AddBezier(cx, bottom, bounds.X, bounds.Y + bounds.Height * 0.66f, bounds.X, bounds.Y + bounds.Height * 0.34f, cx, top);
        path.CloseFigure();
        return path;
    }
}

static class Theme
{
    public static readonly Font BodyFont = PreferredFont("Segoe UI Variable Text", 9.6f, FontStyle.Regular);
    public static readonly Font SmallFont = PreferredFont("Segoe UI Variable Text", 8.7f, FontStyle.Regular);
    public static readonly Font StatusFont = PreferredFont("Segoe UI Variable Text", 11.2f, FontStyle.Bold);
    public static readonly Font SectionFont = PreferredFont("Segoe UI Variable Text", 12.4f, FontStyle.Bold);
    public static readonly Font DisplayFont = PreferredFont("Segoe UI Variable Display", 22.5f, FontStyle.Bold);
    public static readonly Font ActionFont = PreferredFont("Segoe UI Variable Display", 18.5f, FontStyle.Bold);
    public static readonly Color Surface = Color.FromArgb(245, 248, 252);
    public static readonly Color Text = Color.FromArgb(24, 32, 43);
    public static readonly Color Muted = Color.FromArgb(96, 111, 128);
    public static readonly Color Border = Color.FromArgb(218, 226, 236);
    public static readonly Color Blue = Color.FromArgb(18, 111, 214);
    public static readonly Color Cyan = Color.FromArgb(51, 197, 232);
    public static readonly Color Green = Color.FromArgb(22, 147, 98);
    public static readonly Color Red = Color.FromArgb(207, 63, 75);

    private static Font PreferredFont(string family, float size, FontStyle style)
    {
        try
        {
            using var test = new FontFamily(family);
            return new Font(test, size, style, GraphicsUnit.Point);
        }
        catch
        {
            return new Font("Segoe UI", size, style, GraphicsUnit.Point);
        }
    }
}
