using Microsoft.Extensions.Configuration;
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

        var tokenDialog = new TelegramTokenDialog(_configuration);
        tokenDialog.ShowDialog();

        var mainWindow = new MainWindow(_batchService);
        Application.Top.Add(mainWindow);

        Application.Top.Unloaded += _ =>
        {
            _lifetime.StopApplication();
        };

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
