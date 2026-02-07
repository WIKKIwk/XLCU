// ============================================
// TITAN.TUI - Terminal User Interface
// ============================================
// File: src/Titan.TUI/Titan.TUI.csproj
/*
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>Titan.TUI</RootNamespace>
    <LangVersion>14.0</LangVersion>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="../Titan.Domain/Titan.Domain.csproj" />
    <ProjectReference Include="../Titan.Core/Titan.Core.csproj" />
    <ProjectReference Include="../Titan.Infrastructure/Titan.Infrastructure.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Terminal.Gui" Version="2.0.0" />
    <PackageReference Include="Microsoft.Extensions.Hosting" Version="10.0.0-preview.1.25080.5" />
  </ItemGroup>
</Project>
*/

// ============================================
// File: src/Titan.TUI/Views/MainWindow.cs
// ============================================
using Terminal.Gui;
using Titan.Core.Fsm;
using Titan.Core.Services;

namespace Titan.TUI.Views;

public sealed class MainWindow : Window
{
    private readonly BatchProcessingService _batchService;
    private readonly Label _statusLabel;
    private readonly Label _batchLabel;
    private readonly Label _productLabel;
    private readonly Label _weightLabel;
    private readonly Label _countLabel;
    private readonly Button _startButton;
    private readonly Button _stopButton;
    private readonly Button _settingsButton;
    private readonly ProgressBar _stabilityBar;

    private int _printCount = 0;

    public MainWindow(BatchProcessingService batchService) : base("TITAN CORE - RFID/Zebra Warehouse System")
    {
        _batchService = batchService;
        
        X = 0;
        Y = 0;
        Width = Dim.Fill();
        Height = Dim.Fill();
        ColorScheme = Colors.Base;

        // Status Frame
        var statusFrame = new FrameView("Status")
        {
            X = 0,
            Y = 0,
            Width = Dim.Fill(),
            Height = 8
        };

        _statusLabel = new Label("State: IDLE") { X = 1, Y = 0 };
        _batchLabel = new Label("Batch: -") { X = 1, Y = 1 };
        _productLabel = new Label("Product: -") { X = 1, Y = 2 };
        _weightLabel = new Label("Weight: 0.000 kg") { X = 1, Y = 3 };
        _countLabel = new Label("Printed: 0") { X = 1, Y = 4 };
        
        _stabilityBar = new ProgressBar()
        {
            X = 1,
            Y = 6,
            Width = Dim.Fill(2),
            Height = 1,
            Fraction = 0
        };

        statusFrame.Add(_statusLabel, _batchLabel, _productLabel, _weightLabel, _countLabel, _stabilityBar);
        
        // Controls Frame
        var controlsFrame = new FrameView("Controls")
        {
            X = 0,
            Y = Pos.Bottom(statusFrame) + 1,
            Width = Dim.Fill(),
            Height = 6
        };

        _startButton = new Button("Start Batch", true)
        {
            X = 1,
            Y = 0
        };
        _startButton.Clicked += OnStartBatch;

        _stopButton = new Button("Stop Batch")
        {
            X = Pos.Right(_startButton) + 2,
            Y = 0
        };
        _stopButton.Clicked += OnStopBatch;

        _settingsButton = new Button("Settings")
        {
            X = Pos.Right(_stopButton) + 2,
            Y = 0
        };
        _settingsButton.Clicked += OnSettings;

        controlsFrame.Add(_startButton, _stopButton, _settingsButton);

        // Log Frame
        var logFrame = new FrameView("Event Log")
        {
            X = 0,
            Y = Pos.Bottom(controlsFrame) + 1,
            Width = Dim.Fill(),
            Height = Dim.Fill()
        };

        var logView = new ListView()
        {
            X = 0,
            Y = 0,
            Width = Dim.Fill(),
            Height = Dim.Fill(),
            AllowsMarking = false
        };
        logFrame.Add(logView);

        Add(statusFrame, controlsFrame, logFrame);

        // Timer for UI updates
        Application.MainLoop.AddTimeout(TimeSpan.FromMilliseconds(100), _ =>
        {
            UpdateUI();
            return true;
        });
    }

    private void UpdateUI()
    {
        var state = _batchService.CurrentState;
        _statusLabel.Text = $"State: {state}";
        _batchLabel.Text = $"Batch: {_batchService.ActiveBatchId ?? "-"}";
        _productLabel.Text = $"Product: {_batchService.ActiveProductId ?? "-"}";
        
        if (_batchService.CurrentWeight.HasValue)
        {
            _weightLabel.Text = $"Weight: {_batchService.CurrentWeight.Value:F3} kg";
        }
        
        _countLabel.Text = $"Printed: {_printCount}";

        // Update button states
        _startButton.Enabled = state == BatchProcessingState.Idle || state == BatchProcessingState.Paused;
        _stopButton.Enabled = state != BatchProcessingState.Idle;

        // Update stability bar based on state
        _stabilityBar.Fraction = state switch
        {
            BatchProcessingState.WaitEmpty => 0,
            BatchProcessingState.Loading => 0.25,
            BatchProcessingState.Settling => 0.5,
            BatchProcessingState.Locked => 0.75,
            BatchProcessingState.Printing => 1.0,
            BatchProcessingState.PostGuard => 0.9,
            _ => 0
        };

        // Color coding
        _statusLabel.ColorScheme = state switch
        {
            BatchProcessingState.Printing => new ColorScheme { Normal = new Terminal.Gui.Attribute(Color.Black, Color.Green) },
            BatchProcessingState.Locked => new ColorScheme { Normal = new Terminal.Gui.Attribute(Color.Black, Color.BrightYellow) },
            BatchProcessingState.Paused => new ColorScheme { Normal = new Terminal.Gui.Attribute(Color.Black, Color.Red) },
            _ => Colors.Base
        };
    }

    private void OnStartBatch()
    {
        var dialog = new BatchStartDialog();
        var result = dialog.ShowDialog();
        
        if (result && !string.IsNullOrEmpty(dialog.BatchId) && !string.IsNullOrEmpty(dialog.ProductId))
        {
            _batchService.StartBatch(dialog.BatchId, dialog.ProductId, dialog.MinWeight);
            _printCount = 0;
        }
    }

    private void OnStopBatch()
    {
        if (MessageBox.Query("Confirm", "Stop current batch?", "Yes", "No") == 0)
        {
            _batchService.StopBatch();
        }
    }

    private void OnSettings()
    {
        var settingsDialog = new SettingsDialog();
        settingsDialog.ShowModal();
    }
}

// ============================================
// File: src/Titan.TUI/Views/BatchStartDialog.cs
// ============================================
using Terminal.Gui;

namespace Titan.TUI.Views;

public class BatchStartDialog : Dialog
{
    public string? BatchId { get; private set; }
    public string? ProductId { get; private set; }
    public double MinWeight { get; private set; } = 1.0;

    public BatchStartDialog() : base("Start New Batch", 60, 15)
    {
        var batchLabel = new Label("Batch ID:") { X = 1, Y = 1 };
        var batchField = new TextField("") { X = 15, Y = 1, Width = 40 };

        var productLabel = new Label("Product ID:") { X = 1, Y = 3 };
        var productField = new TextField("") { X = 15, Y = 3, Width = 40 };

        var weightLabel = new Label("Min Weight:") { X = 1, Y = 5 };
        var weightField = new TextField("1.0") { X = 15, Y = 5, Width = 10 };

        var btnOk = new Button("Start", true);
        btnOk.Clicked += () =>
        {
            BatchId = batchField.Text.ToString();
            ProductId = productField.Text.ToString();
            if (double.TryParse(weightField.Text.ToString(), out var w))
                MinWeight = w;
            
            Application.RequestStop();
        };

        var btnCancel = new Button("Cancel");
        btnCancel.Clicked += () => Application.RequestStop();

        Add(batchLabel, batchField, productLabel, productField, weightLabel, weightField);
        AddButton(btnOk);
        AddButton(btnCancel);
    }

    public new bool ShowDialog()
    {
        ShowModal();
        return !string.IsNullOrEmpty(BatchId);
    }
}

// ============================================
// File: src/Titan.TUI/Views/SettingsDialog.cs
// ============================================
using Terminal.Gui;

namespace Titan.TUI.Views;

public class SettingsDialog : Dialog
{
    public SettingsDialog() : base("Settings", 70, 20)
    {
        var tabs = new TabView()
        {
            X = 0,
            Y = 0,
            Width = Dim.Fill(),
            Height = Dim.Fill(2)
        };

        // Hardware Tab
        var hardwareTab = new Tab("Hardware", new FrameView("Hardware Settings")
        {
            Width = Dim.Fill(),
            Height = Dim.Fill()
        });
        
        hardwareTab.View.Add(new Label("Scale Port:") { X = 1, Y = 1 });
        hardwareTab.View.Add(new TextField("/dev/ttyUSB0") { X = 20, Y = 1, Width = 30 });
        
        hardwareTab.View.Add(new Label("Printer Device:") { X = 1, Y = 3 });
        hardwareTab.View.Add(new TextField("/dev/usb/lp0") { X = 20, Y = 3, Width = 30 });

        // Network Tab
        var networkTab = new Tab("Network", new FrameView("Network Settings")
        {
            Width = Dim.Fill(),
            Height = Dim.Fill()
        });
        
        networkTab.View.Add(new Label("Elixir URL:") { X = 1, Y = 1 });
        networkTab.View.Add(new TextField("http://localhost:4000") { X = 20, Y = 1, Width = 40 });
        
        networkTab.View.Add(new Label("API Token:") { X = 1, Y = 3 });
        var tokenField = new TextField("") { X = 20, Y = 3, Width = 40, Secret = true };
        networkTab.View.Add(tokenField);

        tabs.AddTab(hardwareTab, true);
        tabs.AddTab(networkTab, false);

        var btnSave = new Button("Save", true);
        btnSave.Clicked += () =>
        {
            // Save settings logic
            Application.RequestStop();
        };

        var btnCancel = new Button("Cancel");
        btnCancel.Clicked += () => Application.RequestStop();

        Add(tabs);
        AddButton(btnSave);
        AddButton(btnCancel);
    }
}

// ============================================
// File: src/Titan.TUI/Services/TuiHostedService.cs
// ============================================
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Terminal.Gui;
using Titan.Core.Services;
using Titan.TUI.Views;

namespace Titan.TUI.Services;

public class TuiHostedService : IHostedService
{
    private readonly ILogger<TuiHostedService> _logger;
    private readonly BatchProcessingService _batchService;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly IConfiguration _configuration;

    public TuiHostedService(
        ILogger<TuiHostedService> logger,
        BatchProcessingService batchService,
        IHostApplicationLifetime lifetime,
        IConfiguration configuration)
    {
        _logger = logger;
        _batchService = batchService;
        _lifetime = lifetime;
        _configuration = configuration;
    }

    public Task StartAsync(CancellationToken ct)
    {
        _logger.LogInformation("Starting TUI application");
        
        Application.Init();

        // Ask for Telegram bot token on startup (core -> LCE)
        var tokenDialog = new TelegramTokenDialog(_configuration);
        tokenDialog.ShowDialog();
        
        var mainWindow = new MainWindow(_batchService);
        Application.Top.Add(mainWindow);
        
        // Handle application exit
        Application.Top.Unloaded += _ =>
        {
            _lifetime.StopApplication();
        };

        // Run UI in background thread
        Task.Run(() => Application.Run(), ct);
        
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken ct)
    {
        _logger.LogInformation("Stopping TUI application");
        Application.Shutdown();
        return Task.CompletedTask;
    }
}

// ============================================
// File: src/Titan.TUI/Views/TelegramTokenDialog.cs
// ============================================
using System.Net.Http.Json;
using Microsoft.Extensions.Configuration;
using Terminal.Gui;

namespace Titan.TUI.Views;

public sealed class TelegramTokenDialog : Dialog
{
    private readonly IConfiguration _configuration;

    public TelegramTokenDialog(IConfiguration configuration) : base("Telegram Token", 70, 15)
    {
        _configuration = configuration;

        var tokenLabel = new Label("Telegram Bot Token:") { X = 1, Y = 1 };
        var tokenField = new TextField("") { X = 25, Y = 1, Width = 40 };

        var urlLabel = new Label("LCE URL:") { X = 1, Y = 3 };
        var urlDefault = _configuration.GetValue<string>("Elixir:Url") ?? "http://127.0.0.1:4000";
        var urlField = new TextField(urlDefault) { X = 25, Y = 3, Width = 40 };

        var note = new Label("Token LCE ga yuboriladi va DB da saqlanadi.") { X = 1, Y = 5 };

        var btnSave = new Button("Save", true);
        btnSave.Clicked += () =>
        {
            var token = tokenField.Text.ToString() ?? "";
            var url = urlField.Text.ToString() ?? "";
            if (!string.IsNullOrWhiteSpace(token) && !string.IsNullOrWhiteSpace(url))
            {
                _ = LceConfigClient.SendTelegramTokenAsync(url, token);
            }
            Application.RequestStop();
        };

        var btnSkip = new Button("Skip");
        btnSkip.Clicked += () => Application.RequestStop();

        Add(tokenLabel, tokenField, urlLabel, urlField, note);
        AddButton(btnSave);
        AddButton(btnSkip);
    }

    public void ShowDialog()
    {
        Application.Run(this);
    }
}

public static class LceConfigClient
{
    public static async Task<bool> SendTelegramTokenAsync(string baseUrl, string token)
    {
        try
        {
            using var client = new HttpClient();
            client.BaseAddress = new Uri(baseUrl.TrimEnd('/'));
            var payload = new { telegram_token = token };
            var res = await client.PostAsJsonAsync("/api/config", payload);
            return res.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }
}
