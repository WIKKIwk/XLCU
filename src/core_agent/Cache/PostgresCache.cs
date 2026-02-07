using Npgsql;

namespace CoreAgent.Cache;

public sealed class PostgresCache
{
    private readonly string _connectionString;
    private readonly string _schema;

    public PostgresCache(string connectionString, string schema)
    {
        _connectionString = connectionString;
        _schema = schema;
    }

    public async Task EnsureAsync(CancellationToken ct)
    {
        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync(ct);

        await using var cmd = conn.CreateCommand();
        cmd.CommandText = $@"
CREATE SCHEMA IF NOT EXISTS {_schema};
CREATE TABLE IF NOT EXISTS {_schema}.items (
  name text PRIMARY KEY,
  item_name text,
  stock_uom text,
  disabled boolean NOT NULL DEFAULT false,
  updated_at timestamp without time zone DEFAULT now()
);
CREATE TABLE IF NOT EXISTS {_schema}.warehouses (
  name text PRIMARY KEY,
  warehouse_name text,
  disabled boolean NOT NULL DEFAULT false,
  is_group boolean NOT NULL DEFAULT false,
  updated_at timestamp without time zone DEFAULT now()
);
CREATE TABLE IF NOT EXISTS {_schema}.stock_drafts (
  name text PRIMARY KEY,
  purpose text,
  from_warehouse text,
  to_warehouse text,
  docstatus integer,
  updated_at timestamp without time zone DEFAULT now()
);
";
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task LoadIntoAsync(LocalCache cache, CancellationToken ct)
    {
        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync(ct);

        var items = new List<ItemRow>();
        var warehouses = new List<WarehouseRow>();
        var drafts = new List<StockDraftRow>();

        await using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = $"SELECT name, item_name, stock_uom, disabled FROM {_schema}.items";
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                items.Add(new ItemRow(
                    reader.GetString(0),
                    reader.IsDBNull(1) ? null : reader.GetString(1),
                    reader.IsDBNull(2) ? null : reader.GetString(2),
                    !reader.IsDBNull(3) && reader.GetBoolean(3)
                ));
            }
        }

        await using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = $"SELECT name, warehouse_name, disabled, is_group FROM {_schema}.warehouses";
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                warehouses.Add(new WarehouseRow(
                    reader.GetString(0),
                    reader.IsDBNull(1) ? null : reader.GetString(1),
                    !reader.IsDBNull(2) && reader.GetBoolean(2),
                    !reader.IsDBNull(3) && reader.GetBoolean(3)
                ));
            }
        }

        await using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = $"SELECT name, purpose, from_warehouse, to_warehouse, docstatus FROM {_schema}.stock_drafts";
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                drafts.Add(new StockDraftRow(
                    reader.GetString(0),
                    reader.IsDBNull(1) ? null : reader.GetString(1),
                    reader.IsDBNull(2) ? null : reader.GetString(2),
                    reader.IsDBNull(3) ? null : reader.GetString(3),
                    reader.IsDBNull(4) ? 0 : reader.GetInt32(4)
                ));
            }
        }

        cache.ReplaceItems(items);
        cache.ReplaceWarehouses(warehouses);
        cache.ReplaceDrafts(drafts);
    }

    public async Task ReplaceItemsAsync(IEnumerable<ItemRow> items, CancellationToken ct)
    {
        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        await using (var clear = conn.CreateCommand())
        {
            clear.CommandText = $"DELETE FROM {_schema}.items";
            await clear.ExecuteNonQueryAsync(ct);
        }

        await using var insert = conn.CreateCommand();
        insert.CommandText = $"INSERT INTO {_schema}.items (name, item_name, stock_uom, disabled, updated_at) VALUES (@name, @item_name, @stock_uom, @disabled, now())";
        var pName = insert.Parameters.Add("name", NpgsqlTypes.NpgsqlDbType.Text);
        var pItemName = insert.Parameters.Add("item_name", NpgsqlTypes.NpgsqlDbType.Text);
        var pStock = insert.Parameters.Add("stock_uom", NpgsqlTypes.NpgsqlDbType.Text);
        var pDisabled = insert.Parameters.Add("disabled", NpgsqlTypes.NpgsqlDbType.Boolean);

        foreach (var item in items)
        {
            pName.Value = item.Name;
            pItemName.Value = (object?)item.ItemName ?? DBNull.Value;
            pStock.Value = (object?)item.StockUom ?? DBNull.Value;
            pDisabled.Value = item.Disabled;
            await insert.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
    }

    public async Task ReplaceWarehousesAsync(IEnumerable<WarehouseRow> warehouses, CancellationToken ct)
    {
        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        await using (var clear = conn.CreateCommand())
        {
            clear.CommandText = $"DELETE FROM {_schema}.warehouses";
            await clear.ExecuteNonQueryAsync(ct);
        }

        await using var insert = conn.CreateCommand();
        insert.CommandText = $"INSERT INTO {_schema}.warehouses (name, warehouse_name, disabled, is_group, updated_at) VALUES (@name, @warehouse_name, @disabled, @is_group, now())";
        var pName = insert.Parameters.Add("name", NpgsqlTypes.NpgsqlDbType.Text);
        var pWName = insert.Parameters.Add("warehouse_name", NpgsqlTypes.NpgsqlDbType.Text);
        var pDisabled = insert.Parameters.Add("disabled", NpgsqlTypes.NpgsqlDbType.Boolean);
        var pGroup = insert.Parameters.Add("is_group", NpgsqlTypes.NpgsqlDbType.Boolean);

        foreach (var wh in warehouses)
        {
            pName.Value = wh.Name;
            pWName.Value = (object?)wh.WarehouseName ?? DBNull.Value;
            pDisabled.Value = wh.Disabled;
            pGroup.Value = wh.IsGroup;
            await insert.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
    }

    public async Task ReplaceDraftsAsync(IEnumerable<StockDraftRow> drafts, CancellationToken ct)
    {
        await using var conn = new NpgsqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        await using (var clear = conn.CreateCommand())
        {
            clear.CommandText = $"DELETE FROM {_schema}.stock_drafts";
            await clear.ExecuteNonQueryAsync(ct);
        }

        await using var insert = conn.CreateCommand();
        insert.CommandText = $"INSERT INTO {_schema}.stock_drafts (name, purpose, from_warehouse, to_warehouse, docstatus, updated_at) VALUES (@name, @purpose, @from_warehouse, @to_warehouse, @docstatus, now())";
        var pName = insert.Parameters.Add("name", NpgsqlTypes.NpgsqlDbType.Text);
        var pPurpose = insert.Parameters.Add("purpose", NpgsqlTypes.NpgsqlDbType.Text);
        var pFrom = insert.Parameters.Add("from_warehouse", NpgsqlTypes.NpgsqlDbType.Text);
        var pTo = insert.Parameters.Add("to_warehouse", NpgsqlTypes.NpgsqlDbType.Text);
        var pStatus = insert.Parameters.Add("docstatus", NpgsqlTypes.NpgsqlDbType.Integer);

        foreach (var d in drafts)
        {
            pName.Value = d.Name;
            pPurpose.Value = (object?)d.Purpose ?? DBNull.Value;
            pFrom.Value = (object?)d.FromWarehouse ?? DBNull.Value;
            pTo.Value = (object?)d.ToWarehouse ?? DBNull.Value;
            pStatus.Value = d.Docstatus;
            await insert.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
    }
}
