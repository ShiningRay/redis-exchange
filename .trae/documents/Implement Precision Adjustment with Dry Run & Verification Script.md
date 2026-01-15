# Implement Precision Adjustment Maintenance Script with Dry Run

## Objective
Add a `dry` run mode to `update_market_precision` to simulate changes without applying them, and create a comprehensive maintenance script `script/maintenance/adjust_precision.rb` that uses this mode to verify safety before executing precision updates.

## Changes

### 1. Modify `RedisExchange::Maintenance#update_market_precision`
- **File**: `lib/redis_exchange/maintenance.rb`
- Add `dry: false` parameter.
- When `dry: true`:
  - Call a new private method `simulate_precision_update`.
  - Return `{ new_order_book: Hash, revised_balances: Array, status: 'SIMULATED' }`.
- When `dry: false`:
  - Execute existing logic (Lua scripts).

### 2. Implement `simulate_precision_update` (Private)
- Replicate the logic of `migrate_orders_batch.lua` in Ruby:
  - Fetch current market config and calculate scaling factors.
  - Iterate through all active orders in the book.
  - Calculate `new_price`, `new_quantity`, `new_remaining`.
  - Calculate `new_reserved_base` and `new_reserved_quote` using the new scales.
  - Determine "Dust Refunds" (`old_reserved - new_reserved`).
  - Construct the `new_order_book` structure.
  - Accumulate balance changes in `revised_balances`.

### 3. Create `script/maintenance/adjust_precision.rb`
- **Workflow**:
  1. **Snapshot**:
     - `old_balances = client.maintenance.snapshot_balances`
     - `old_book = client.maintenance.snapshot_order_book`
  2. **Simulate**:
     - Run `update_market_precision(..., dry: true)`.
  3. **Verify (Pre-Check)**:
     - Check that `Total Balance` (Available + Reserved) remains invariant for all users/assets based on the simulation results.
     - Display summary of changes (orders modified, dust released).
  4. **Execute**:
     - Ask for user confirmation.
     - Run `update_market_precision(..., dry: false)`.
  5. **Verify (Post-Check)**:
     - `new_balances = client.maintenance.snapshot_balances`
     - `new_book = client.maintenance.snapshot_order_book`
     - **Critical Invariant Check**: Verify `old_balances` vs `new_balances`:
       - `(Old Available + Old Reserved) == (New Available + New Reserved)` for every user/asset.
       - Report any discrepancies.

## Verification
- Run the script in `dry` mode on a test market with orders.
- Verify that it correctly predicts the new state.
- Run the script in execute mode and confirm the invariant holds.
