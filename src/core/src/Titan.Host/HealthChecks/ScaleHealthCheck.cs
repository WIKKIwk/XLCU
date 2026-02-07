using Microsoft.Extensions.Diagnostics.HealthChecks;
using Titan.Infrastructure.Hardware.Scale;

namespace Titan.Host.HealthChecks;

public class ScaleHealthCheck : IHealthCheck
{
    private readonly IScalePort _scalePort;

    public ScaleHealthCheck(IScalePort scalePort) => _scalePort = scalePort;

    public Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        return Task.FromResult(_scalePort.IsConnected
            ? HealthCheckResult.Healthy("Scale is connected")
            : HealthCheckResult.Degraded("Scale is not connected"));
    }
}
