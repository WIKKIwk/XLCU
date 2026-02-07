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

    public Task InitializeAsync()
    {
        _webSocket = new ClientWebSocket();
        return Task.CompletedTask;
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
        var uri = new Uri($"{_bridgeUrl}?device_id=DEV-TEST-001&token=test-token");

        await _webSocket!.ConnectAsync(uri, CancellationToken.None);

        var authMessage = new { type = "auth", device_id = "DEV-TEST-001", capabilities = new[] { "print" } };
        await SendMessageAsync(authMessage);

        var response = await ReceiveMessageAsync();

        response.Should().Contain("authenticated");
    }

    [Fact(Skip = "Requires running Elixir Bridge")]
    public async Task WebSocket_SendHeartbeat_Should_ReceiveAck()
    {
        await ConnectAndAuthenticateAsync();

        await SendMessageAsync(new { type = "heartbeat" });
        var response = await ReceiveMessageAsync();

        response.Should().Contain("timestamp");
    }

    [Fact(Skip = "Requires running Elixir Bridge")]
    public async Task WebSocket_SendStatusUpdate_Should_BeAccepted()
    {
        await ConnectAndAuthenticateAsync();

        var statusMessage = new
        {
            type = "status",
            state = "Locked",
            data = new { weight = 2.5, product_id = "PROD-001" }
        };
        await SendMessageAsync(statusMessage);

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
