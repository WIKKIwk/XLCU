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
            Application.RequestStop();
        };

        var btnCancel = new Button("Cancel");
        btnCancel.Clicked += () => Application.RequestStop();

        Add(tabs);
        AddButton(btnSave);
        AddButton(btnCancel);
    }
}
