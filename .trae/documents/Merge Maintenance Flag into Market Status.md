I will merge the `maintenance` field into the `status` field by introducing a new `MAINTENANCE` state. This simplifies the data model while preserving the distinct behaviors (blocking cancellations during atomic operations vs. allowing cancellations during normal halts).

### Plan

1.  **Update Lua Scripts**:
    *   Modify `match_order.lua`: Remove the check for the `maintenance` field. Update the logic to reject orders if `status` is `MAINTENANCE`.
    *   Modify `cancel_order.lua`: Remove the check for the `maintenance` field. Update the logic to reject cancellations **only** if `status` is `MAINTENANCE` (preserving the ability to cancel in `HALTED` or `CLOSED` states).

2.  **Update Ruby Code (`RedisExchange::Maintenance`)**:
    *   Modify `enable_market(symbol)` to set `status` to `'MAINTENANCE'`.
    *   Modify `disable_market(symbol)` to set `status` to `'OPEN'`.
    *   Update `snapshot_order_book` to capture the *original* status before enabling maintenance, and restore that specific status afterwards (preventing accidental opening of a previously `HALTED` market).

3.  **Documentation**:
    *   Update `README.md` to include `MAINTENANCE` in the list of valid market statuses.

### Verification
*   I will verify that `match_order` blocks new orders in `MAINTENANCE` mode.
*   I will verify that `cancel_order` blocks cancellations in `MAINTENANCE` mode.
*   I will verify that `snapshot_order_book` correctly restores the original market status (e.g., if it was `HALTED`, it returns to `HALTED`).