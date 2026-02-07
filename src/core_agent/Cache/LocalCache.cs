namespace CoreAgent.Cache;

public sealed class LocalCache
{
    private readonly Dictionary<string, ItemRow> _items = new();
    private readonly Dictionary<string, WarehouseRow> _warehouses = new();
    private readonly Dictionary<string, StockDraftRow> _drafts = new();

    public LocalCache(string dir)
    {
        _ = dir;
    }

    public void Load()
    {
        // no-op (in-memory only)
    }

    public void Save()
    {
        // no-op (in-memory only)
    }

    public void ReplaceItems(IEnumerable<ItemRow> items)
    {
        _items.Clear();
        foreach (var item in items)
        {
            if (!string.IsNullOrWhiteSpace(item.Name))
            {
                _items[item.Name] = item;
            }
        }
    }

    public void ReplaceWarehouses(IEnumerable<WarehouseRow> warehouses)
    {
        _warehouses.Clear();
        foreach (var wh in warehouses)
        {
            if (!string.IsNullOrWhiteSpace(wh.Name))
            {
                _warehouses[wh.Name] = wh;
            }
        }
    }

    public void ReplaceDrafts(IEnumerable<StockDraftRow> drafts)
    {
        _drafts.Clear();
        foreach (var d in drafts)
        {
            if (!string.IsNullOrWhiteSpace(d.Name))
            {
                _drafts[d.Name] = d;
            }
        }
    }

    public IReadOnlyCollection<ItemRow> Items => _items.Values;
    public IReadOnlyCollection<WarehouseRow> Warehouses => _warehouses.Values;
    public IReadOnlyCollection<StockDraftRow> Drafts => _drafts.Values;

}

public interface IKeyed
{
    string Key { get; }
}

public record ItemRow(string Name, string? ItemName, string? StockUom, bool Disabled) : IKeyed
{
    public string Key => Name;
}

public record WarehouseRow(string Name, string? WarehouseName, bool Disabled, bool IsGroup) : IKeyed
{
    public string Key => Name;
}

public record StockDraftRow(string Name, string? Purpose, string? FromWarehouse, string? ToWarehouse, int Docstatus) : IKeyed
{
    public string Key => Name;
}
