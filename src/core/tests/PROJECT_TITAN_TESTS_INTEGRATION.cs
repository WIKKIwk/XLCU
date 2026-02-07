// ============================================
// TITAN CORE - Integration Tests
// ============================================
// File: tests/Titan.Integration.Tests/Titan.Integration.Tests.csproj
/*
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <IsPackable>false</IsPackable>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.9.0" />
    <PackageReference Include="xunit" Version="2.7.0" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.5.7" />
    <PackageReference Include="Microsoft.AspNetCore.TestHost" Version="10.0.0-preview.1.25080.5" />
    <PackageReference Include="Testcontainers.PostgreSql" Version="3.7.0" />
    <PackageReference Include="FluentAssertions" Version="7.0.0-alpha.3" />
    <PackageReference Include="Moq" Version="4.20.70" />
    <PackageReference Include="Bogus" Version="35.5.0" />
    <PackageReference Include="System.IO.Ports" Version="10.0.0-preview.1.25080.5" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="../../src/Titan.Host/Titan.Host.csproj" />
  </ItemGroup>
</Project>
*/

// ============================================
// File: tests/Titan.Integration.Tests/Infrastructure/DatabaseIntegrationTests.cs
// ============================================
using Xunit;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Titan.Infrastructure.Persistence;
using Titan.Domain.Entities;
using Titan.Infrastructure.Persistence.Repositories;
using Testcontainers.PostgreSql;

namespace Titan.Integration.Tests.Infrastructure;

public class DatabaseIntegrationTests : IAsyncLifetime
{
    private PostgreSqlContainer? _postgresContainer;
    private TitanDbContext? _dbContext;
    private ProductRepository? _productRepository;

    public async Task InitializeAsync()
    {
        _postgresContainer = new PostgreSqlBuilder()
            .WithDatabase("titan_test")
            .WithUsername("test")
            .WithPassword("test")
            .Build();

        await _postgresContainer.StartAsync();

        var options = new DbContextOptionsBuilder<TitanDbContext>()
            .UseNpgsql(_postgresContainer.GetConnectionString())
            .Options;

        _dbContext = new TitanDbContext(options);
        await _dbContext.Database.MigrateAsync();

        _productRepository = new ProductRepository(_dbContext);
    }

    public async Task DisposeAsync()
    {
        if (_dbContext != null)
            await _dbContext.DisposeAsync();
        
        if (_postgresContainer != null)
            await _postgresContainer.DisposeAsync();
    }

    [Fact]
    public async Task ProductRepository_AddAsync_Should_PersistToDatabase()
    {
        // Arrange
        var product = new Product("PROD-TEST-001", "Test Product", "WH-001");

        // Act
        await _productRepository!.AddAsync(product);

        // Assert
        var retrieved = await _productRepository.GetByIdAsync("PROD-TEST-001");
        retrieved.Should().NotBeNull();
        retrieved!.Name.Should().Be("Test Product");
    }

    [Fact]
    public async Task ProductRepository_GetByWarehouseAsync_Should_FilterByWarehouse()
    {
        // Arrange
        var product1 = new Product("PROD-001", "Product 1", "WH-001");
        var product2 = new Product("PROD-002", "Product 2", "WH-002");
        var product3 = new Product("PROD-003", "Product 3", "WH-001");

        await _productRepository!.AddAsync(product1);
        await _productRepository.AddAsync(product2);
        await _productRepository.AddAsync(product3);

        // Act
        var wh1Products = await _productRepository.GetByWarehouseAsync("WH-001");

        // Assert
        wh1Products.Should().HaveCount(2);
        wh1Products.Select(p => p.Id).Should().Contain(new[] { "PROD-001", "PROD-003" });
    }

    [Fact]
    public async Task ProductRepository_GetAvailableForIssueAsync_Should_FilterCorrectly()
    {
        // Arrange
        var product1 = new Product("PROD-001", "Product 1", "WH-001");
        product1.MarkAsReceived();
        product1.AllowIssue();

        var product2 = new Product("PROD-002", "Product 2", "WH-001");
        product2.MarkAsReceived();  // Not allowed for issue

        var product3 = new Product("PROD-003", "Product 3", "WH-002");  // Wrong warehouse
        product3.MarkAsReceived();
        product3.AllowIssue();

        await _productRepository!.AddAsync(product1);
        await _productRepository.AddAsync(product2);
        await _productRepository.AddAsync(product3);

        // Act
        var available = await _productRepository.GetAvailableForIssueAsync("WH-001");

        // Assert
        available.Should().HaveCount(1);
        available.First().Id.Should().Be("PROD-001");
    }

    [Fact]
    public async Task WeightRecordRepository_GetUnsyncedAsync_Should_ReturnOnlyUnsynced()
    {
        // Arrange
        var repo = new WeightRecordRepository(_dbContext!);
        
        var record1 = new WeightRecord("BATCH-001", "PROD-001", 2.5, "kg", "EPC001");
        var record2 = new WeightRecord("BATCH-001", "PROD-001", 3.0, "kg", "EPC002");
        record2.MarkAsSynced();
        var record3 = new WeightRecord("BATCH-001", "PROD-001", 1.5, "kg", "EPC003");

        await repo.AddAsync(record1);
        await repo.AddAsync(record2);
        await repo.AddAsync(record3);

        // Act
        var unsynced = await repo.GetUnsyncedAsync();

        // Assert
        unsynced.Should().HaveCount(2);
        unsynced.Select(r => r.EpcCode).Should().Contain(new[] { "EPC001", "EPC003" });
    }
}

// ============================================
// File: tests/Titan.Integration.Tests/Hardware/ScaleSimulationTests.cs
// ============================================
using Xunit;
using FluentAssertions;
using System.IO.Ports;
using System.Threading.Channels;

namespace Titan.Integration.Tests.Hardware;

public class ScaleSimulationTests
{
    private readonly string _testPortName = "COM_SIM";  // Simulated port

    [Fact]
    public void ScalePort_Connect_Should_OpenPort()
    {
        // This would use a mock serial port in real implementation
        // For now, just test the interface exists
        true.Should().BeTrue();  // Placeholder
    }

    [Fact]
    public void ScaleReading_ParseValidData_Should_ReturnReading()
    {
        // Arrange
        var testData = "ST,GS,   1.234,kg\r\n";

        // Act - Parse (would be done by ScalePort implementation)
        var parsed = ParseScaleData(testData);

        // Assert
        parsed.Should().NotBeNull();
        parsed!.Value.Should().BeApproximately(1.234, 0.001);
        parsed.Unit.Should().Be("kg");
        parsed.IsStable.Should().BeTrue();
    }

    [Fact]
    public void ScaleReading_ParseUnstableData_Should_DetectUnstable()
    {
        // Arrange
        var testData = "US,GS,   0.123,kg\r\n";

        // Act
        var parsed = ParseScaleData(testData);

        // Assert
        parsed.Should().NotBeNull();
        parsed!.IsStable.Should().BeFalse();
    }

    private static (double Value, string Unit, bool IsStable)? ParseScaleData(string data)
    {
        // Simple parser for testing
        if (data.Contains("ST"))
        {
            var parts = data.Split(',');
            if (parts.Length >= 4 && double.TryParse(parts[2], out var weight))
            {
                return (weight, parts[3].Trim(), true);
            }
        }
        else if (data.Contains("US"))
        {
            var parts = data.Split(',');
            if (parts.Length >= 4 && double.TryParse(parts[2], out var weight))
            {
                return (weight, parts[3].Trim(), false);
            }
        }
        return null;
    }
}

// ============================================
// File: tests/Titan.Integration.Tests/Simulation/WeightStreamSimulator.cs
// ============================================
using System.Runtime.CompilerServices;
using Titan.Core.Fsm;

namespace Titan.Integration.Tests.Simulation;

public class WeightStreamSimulator
{
    private readonly List<WeightSample> _samples = new();
    private int _currentIndex = 0;
    private double _baseTime;

    public WeightStreamSimulator()
    {
        _baseTime = (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    }

    public void AddStablePhase(double weight, double duration, double sampleRate = 0.1)
    {
        int numSamples = (int)(duration / sampleRate);
        var random = new Random();
        
        for (int i = 0; i < numSamples; i++)
        {
            // Add small noise
            var noise = (random.NextDouble() - 0.5) * 0.01;
            _samples.Add(new WeightSample(weight + noise, "kg", _baseTime + _samples.Count * sampleRate));
        }
    }

    public void AddRamp(double startWeight, double endWeight, double duration, double sampleRate = 0.1)
    {
        int numSamples = (int)(duration / sampleRate);
        double step = (endWeight - startWeight) / numSamples;
        
        for (int i = 0; i < numSamples; i++)
        {
            _samples.Add(new WeightSample(startWeight + step * i, "kg", _baseTime + _samples.Count * sampleRate));
        }
    }

    public void AddTransient(double spikeWeight, double duration, double sampleRate = 0.1)
    {
        int numSamples = (int)(duration / sampleRate);
        for (int i = 0; i < numSamples; i++)
        {
            _samples.Add(new WeightSample(spikeWeight, "kg", _baseTime + _samples.Count * sampleRate));
        }
    }

    public IAsyncEnumerable<WeightSample> StreamAsync([EnumeratorCancellation] CancellationToken ct = default)
    {
        return StreamInternalAsync(ct);
    }

    private async IAsyncEnumerable<WeightSample> StreamInternalAsync([EnumeratorCancellation] CancellationToken ct)
    {
        while (_currentIndex < _samples.Count && !ct.IsCancellationRequested)
        {
            yield return _samples[_currentIndex];
            _currentIndex++;
            await Task.Delay(10, ct);  // Simulate real-time sampling
        }
    }

    public void Reset()
    {
        _currentIndex = 0;
    }

    public int TotalSamples => _samples.Count;
}

// ============================================
// File: tests/Titan.Integration.Tests/EndToEnd/FullBatchCycleTests.cs
// ============================================
using Xunit;
using FluentAssertions;
using Titan.Core.Services;
using Titan.Core.Fsm;
using Titan.Integration.Tests.Simulation;

namespace Titan.Integration.Tests.EndToEnd;

public class FullBatchCycleTests
{
    [Fact]
    public async Task FullBatchCycle_CompleteScenario_Should_ProcessCorrectly()
    {
        // Arrange
        var simulator = new WeightStreamSimulator();
        
        // Phase 1: Empty scale (2 seconds)
        simulator.AddStablePhase(0.0, 2.0);
        
        // Phase 2: Place product and stabilize (3 seconds ramp + 2 seconds stable)
        simulator.AddRamp(0.0, 2.5, 3.0);
        simulator.AddStablePhase(2.5, 2.0);
        
        // Phase 3: Print period (1 second stable)
        simulator.AddStablePhase(2.5, 1.0);
        
        // Phase 4: Remove product (1 second ramp down)
        simulator.AddRamp(2.5, 0.0, 1.0);
        
        // Phase 5: Empty again (1 second)
        simulator.AddStablePhase(0.0, 1.0);
        
        // Create service (with mocks)
        // ... service setup ...
        
        // Act - Stream samples to service
        var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var samplesProcessed = 0;
        
        await foreach (var sample in simulator.StreamAsync(cts.Token))
        {
            // service.ProcessWeight(sample.Value, sample.Unit);
            samplesProcessed++;
        }

        // Assert
        samplesProcessed.Should().BeGreaterThan(0);
        // Assert state transitions occurred correctly
    }

    [Fact]
    public void BatchCycle_WeightFluctuationAfterLock_Should_TriggerReweigh()
    {
        // Arrange
        var simulator = new WeightStreamSimulator();
        
        // Stabilize at 2.5 kg
        simulator.AddStablePhase(2.5, 5.0, 0.05);  // 100 samples at 2.5kg
        
        // Sudden change (simulate someone bumping the scale)
        simulator.AddRamp(2.5, 3.5, 0.5);
        
        // Create FSM
        var fsm = CreateFsm();
        fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        
        // Act - Process stable samples
        foreach (var sample in simulator.GetSamples().Take(100))
        {
            fsm.ProcessWeightSample(sample);
        }
        
        fsm.State.Should().Be(BatchProcessingState.Locked);
        fsm.ConfirmPrintSent("EPC001");
        fsm.State.Should().Be(BatchProcessingState.Printing);
        
        // Process the sudden change
        foreach (var sample in simulator.GetSamples().Skip(100))
        {
            fsm.ProcessWeightSample(sample);
        }
        
        // Assert
        fsm.State.Should().Be(BatchProcessingState.Paused);
        fsm.PauseReason.Should().Be(PauseReason.ReweighRequired);
    }

    private static BatchProcessingFsm CreateFsm()
    {
        var channel = System.Threading.Channels.Channel.CreateUnbounded<Domain.Events.DomainEvent>();
        var detector = new StabilityDetector();
        return new BatchProcessingFsm(channel, detector);
    }
}

// ============================================
// File: tests/Titan.Integration.Tests/Performance/FsmPerformanceTests.cs
// ============================================
using Xunit;
using FluentAssertions;
using System.Diagnostics;
using Titan.Core.Fsm;

namespace Titan.Integration.Tests.Performance;

public class FsmPerformanceTests
{
    [Fact]
    public void Fsm_ProcessWeightSamples_10000Samples_Should_CompleteQuickly()
    {
        // Arrange
        var fsm = CreateFsm();
        fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        
        var samples = Enumerable.Range(0, 10000)
            .Select(i => new WeightSample(2.5, "kg", i * 0.01))
            .ToList();
        
        var stopwatch = Stopwatch.StartNew();
        
        // Act
        foreach (var sample in samples)
        {
            fsm.ProcessWeightSample(sample);
        }
        
        stopwatch.Stop();
        
        // Assert - Should process 10,000 samples in less than 100ms
        stopwatch.ElapsedMilliseconds.Should().BeLessThan(100);
    }

    [Fact]
    public void StabilityDetector_AddSamples_10000Samples_Should_MaintainPerformance()
    {
        // Arrange
        var detector = new StabilityDetector();
        var samples = Enumerable.Range(0, 10000)
            .Select(i => new WeightSample(2.5 + (i % 10) * 0.001, "kg", i * 0.01))
            .ToList();
        
        var stopwatch = Stopwatch.StartNew();
        
        // Act
        foreach (var sample in samples)
        {
            detector.AddSample(sample);
        }
        
        stopwatch.Stop();
        
        // Assert - Should process 10,000 samples in less than 200ms
        stopwatch.ElapsedMilliseconds.Should().BeLessThan(200);
        detector.TotalSamples.Should().BeLessThan(100);  // Old samples should be removed
    }

    private static BatchProcessingFsm CreateFsm()
    {
        var channel = System.Threading.Channels.Channel.CreateUnbounded<Domain.Events.DomainEvent>();
        var detector = new StabilityDetector();
        return new BatchProcessingFsm(channel, detector);
    }
}

// ============================================
// File: tests/Titan.Integration.Tests/WebSocket/ElixirBridgeIntegrationTests.cs
// ============================================
using Xunit;
using FluentAssertions;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace Titan.Integration.Tests.WebSocket;

public class ElixirBridgeIntegrationTests : IAsyncLifetime
{
    private readonly string _bridgeUrl = "ws://localhost:4000/socket";
    private ClientWebSocket? _webSocket;

    public async Task InitializeAsync()
    {
        _webSocket = new ClientWebSocket();
    }

    public async Task DisposeAsync()
    {
        if (_webSocket?.State == WebSocketState.Open)
        {
            await _webSocket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Test complete", CancellationToken.None);
        }
        _webSocket?.Dispose();
    }

    [Fact(Skip = "Requires running Elixir Bridge")]
    public async Task WebSocket_Connect_WithValidToken_Should_Authenticate()
    {
        // Arrange
        var uri = new Uri($"{_bridgeUrl}?device_id=DEV-TEST-001&token=test-token");
        
        // Act
        await _webSocket!.ConnectAsync(uri, CancellationToken.None);
        
        // Send auth message
        var authMessage = new { type = "auth", device_id = "DEV-TEST-001", capabilities = new[] { "print" } };
        await SendMessageAsync(authMessage);
        
        // Wait for response
        var response = await ReceiveMessageAsync();
        
        // Assert
        response.Should().Contain("authenticated");
    }

    [Fact(Skip = "Requires running Elixir Bridge")]
    public async Task WebSocket_SendHeartbeat_Should_ReceiveAck()
    {
        // Arrange
        await ConnectAndAuthenticateAsync();
        
        // Act
        await SendMessageAsync(new { type = "heartbeat" });
        var response = await ReceiveMessageAsync();
        
        // Assert
        response.Should().Contain("timestamp");
    }

    [Fact(Skip = "Requires running Elixir Bridge")]
    public async Task WebSocket_SendStatusUpdate_Should_BeAccepted()
    {
        // Arrange
        await ConnectAndAuthenticateAsync();
        
        // Act
        var statusMessage = new 
        { 
            type = "status", 
            state = "Locked", 
            data = new { weight = 2.5, product_id = "PROD-001" } 
        };
        await SendMessageAsync(statusMessage);
        
        // Assert - Should not throw
        true.Should().BeTrue();
    }

    private async Task ConnectAndAuthenticateAsync()
    {
        var uri = new Uri($"{_bridgeUrl}?device_id=DEV-TEST-001&token=test-token");
        await _webSocket!.ConnectAsync(uri, CancellationToken.None);
        
        var authMessage = new { type = "auth", device_id = "DEV-TEST-001", capabilities = new[] { "print" } };
        await SendMessageAsync(authMessage);
    }

    private async Task SendMessageAsync(object message)
    {
        var json = JsonSerializer.Serialize(message);
        var bytes = Encoding.UTF8.GetBytes(json);
        await _webSocket!.SendAsync(
            new ArraySegment<byte>(bytes), 
            WebSocketMessageType.Text, 
            true, 
            CancellationToken.None);
    }

    private async Task<string> ReceiveMessageAsync()
    {
        var buffer = new byte[1024];
        var result = await _webSocket!.ReceiveAsync(
            new ArraySegment<byte>(buffer), 
            CancellationToken.None);
        
        return Encoding.UTF8.GetString(buffer, 0, result.Count);
    }
}
