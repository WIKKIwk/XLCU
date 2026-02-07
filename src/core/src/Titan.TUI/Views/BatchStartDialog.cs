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
