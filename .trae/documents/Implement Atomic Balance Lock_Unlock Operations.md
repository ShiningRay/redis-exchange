I will implement a unified atomic balance operation system with a standardized ledger format.

## 1. Create `redis_scripts/balance_op.lua`

* **Purpose**: Replaces `balance_change.lua` and provides atomic primitives.

* **Arguments**: `user_id`, `asset`, `amount`, `action`, `reason`, `timestamp`, `biz_id`

* **Actions**:

  * `LOCK`: `available` -> `reserved` (checks avail)

  * `UNLOCK`: `reserved` -> `available` (checks reserved)

  * `ADD`: +`available`

  * `SUB`: -`available` (checks avail)

  * `SUB_LOCKED`: -`reserved` (checks reserved)

  * `ADD_LOCKED`: +`reserved` (for completeness/audits)

* **Ledger Schema**: `user_id`, `asset`, `action`, `amount`, `reason`, `ts`, `sequence`, `biz_id` (Removes `bucket`, adds `action`).

## 2. Refactor Existing Scripts

I will update the following scripts to use the new primitive logic and ledger format (via internal local functions):

* **`match_order.lua`**:

  * `TAKER_RESERVE` -> `LOCK`

  * `TAKER_SPEND` -> `SUB`

  * `TAKER_RECEIVE` -> `ADD`

  * `MAKER_RELEASE` -> `SUB_LOCKED`

  * `MAKER_RECEIVE` -> `ADD`

* **`cancel_order.lua`**:

  * `CANCEL_REFUND` -> `UNLOCK`

* **`audit_user_balance.lua`**:

  * Update `append_ledger` to emit `LOCK`/`UNLOCK` actions instead of bucket deltas.

## 3. Update `lib/redis_exchange.rb`

* **Replace** `balance_change.lua` usage with `balance_op.lua`.

* **Update** `change_balance` to map generic bucket/delta requests to specific actions (`ADD`, `SUB`, `SUB_LOCKED`, etc.).

* **Add** `lock_funds` and `unlock_funds` methods.

* **Deprecate/Delete** `balance_change.lua`.

## 4. Verification

* Create `spec/balance_op_spec.rb` for new primitives.

* Update existing specs (`account_ledger_spec.rb`, etc.) to expect the new ledger format (`action` instead of `bucket`).
