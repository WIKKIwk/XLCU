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

        X = 0; Y = 0;
        Width = Dim.Fill();
        Height = Dim.Fill();
        ColorScheme = Colors.Base;

        var statusFrame = new FrameView("Status") { X = 0, Y = 0, Width = Dim.Fill(), Height = 8 };
        _statusLabel = new Label("State: IDLE") { X = 1, Y = 0 };
        _batchLabel = new Label("Batch: -") { X = 1, Y = 1 };
        _productLabel = new Label("Product: -") { X = 1, Y = 2 };
        _weightLabel = new Label("Weight: 0.000 kg") { X = 1, Y = 3 };
        _countLabel = new Label("Printed: 0") { X = 1, Y = 4 };
        _stabilityBar = new ProgressBar() { X = 1, Y = 6, Width = Dim.Fill(2), Height = 1, Fraction = 0 };
        statusFrame.Add(_statusLabel, _batchLabel, _productLabel, _weightLabel, _countLabel, _stabilityBar);

        var controlsFrame = new FrameView("Controls") { X = 0, Y = Pos.Bottom(statusFrame) + 1, Width = Dim.Fill(), Height = 6 };
        _startButton = new Button("Start Batch", true) { X = 1, Y = 0 };
        _startButton.Clicked += OnStartBatch;
        _stopButton = new Button("Stop Batch") { X = Pos.Right(_startButton) + 2, Y = 0 };
        _stopButton.Clicked += OnStopBatch;
        _settingsButton = new Button("Settings") { X = Pos.Right(_stopButton) + 2, Y = 0 };
        _settingsButton.Clicked += OnSettings;
        controlsFrame.Add(_startButton, _stopButton, _settingsButton);

        var logFrame = new FrameView("Event Log") { X = 0, Y = Pos.Bottom(controlsFrame) + 1, Width = Dim.Fill(), Height = Dim.Fill() };
        var logView = new ListView() { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(), AllowsMarking = false };
        logFrame.Add(logView);

        Add(statusFrame, controlsFrame, logFrame);

        Application.MainLoop.AddTimeout(TimeSpan.FromMilliseconds(100), _ => { UpdateUI(); return true; });
    }

    private void UpdateUI()
    {
        var state = _batchService.CurrentState;
        _statusLabel.Text = $"State: {state}";
        _batchLabel.Text = $"Batch: {_batchService.ActiveBatchId ?? "-"}";
        _productLabel.Text = $"Product: {_batchService.ActiveProductId ?? "-"}";
        if (_batchService.CurrentWeight.HasValue)
            _weightLabel.Text = $"Weight: {_batchService.CurrentWeight.Value:F3} kg";
        _countLabel.Text = $"Printed: {_printCount}";

        _startButton.Enabled = state == BatchProcessingState.Idle || state == BatchProcessingState.Paused;
        _stopButton.Enabled = state != BatchProcessingState.Idle;

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
            _batchService.StopBatch();
    }

    private void OnSettings()
    {
        var settingsDialog = new SettingsDialog();
        settingsDialog.ShowModal();
    }
}
