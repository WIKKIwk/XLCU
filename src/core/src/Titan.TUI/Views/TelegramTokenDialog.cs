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
