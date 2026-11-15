# Portfolio 3: Transactions and Concurrency

**Student:** Ajilore Opeyemi (301930319)
**Case study:** LagoonPay (schema from Portfolio 1, dataset from Portfolio 2)
**Engine:** PostgreSQL 18

## 1. Aim

Show, with output from real runs, how LagoonPay keeps money correct when a transfer fails halfway and when several users touch the same account at the same time. The demos cover commit, rollback, savepoints, the four isolation levels, three concurrency problems (lost update, write skew, deadlock) and the control mechanism that deals with each.

## 2. How two users are simulated

Concurrency needs at least two connections. Typing into two terminals by hand works, but the result depends on timing and is hard to repeat. Instead each script is **session A**, and it opens a second real connection to the same database with the `dblink` extension, which is **session B**. The script then gives the two sessions their statements in a fixed order, so the same interleaving happens on every run. Where B has to be left waiting on a lock, its statement is sent asynchronously (`dblink_send_query`) and collected afterwards.

## 3. Summary of demonstrations

| Demo | What is shown | Mechanism | Observed result |
|---|---|---|---|
| 1A | COMMIT | `BEGIN ... COMMIT` | Debit and credit both applied; two ledger lines written |
| 1B | Explicit ROLLBACK | `ROLLBACK` | Balances return to their earlier values; no transaction row kept |
| 1C | Automatic rollback on error | CHECK (balance >= 0) | Receiver was credited inside the transaction, debit failed, credit undone |
| 1D | Partial rollback | `SAVEPOINT`, `ROLLBACK TO` | Payout to a frozen account undone; the other two payouts committed |
| 1E | Transfer as one function | `transfer_funds()` with an exception block | Failed transfer moves no money and is recorded as FAILED |
| 1F | Durability | Write-ahead log | WAL position advances on commit |
| 2A | Dirty read | MVCC | Not possible, even when READ UNCOMMITTED is requested |
| 2B | Non-repeatable read and phantom | READ COMMITTED | Second read in the same transaction returns a different balance and one more row |
| 2C | Stable snapshot | REPEATABLE READ | Second read is identical; change appears only after commit |
| 2D | Stale write refused | REPEATABLE READ | `could not serialize access due to concurrent update`; retry succeeds |
| 3A | Lost update | None (the bug) | 30,000 withdrawal overwritten |
| 3B | Fix: pessimistic lock | `SELECT ... FOR UPDATE` | B waits for A, then reads the new balance; final balance correct |
| 3C | Fix: optimistic check | `UPDATE ... WHERE balance = old` | B's update matches 0 rows, B retries; final balance correct |
| 3D | Fix: atomic update | `SET balance = balance - x` | Final balance correct, with ledger rows |
| 4A | Write skew | REPEATABLE READ | Both commit; combined-balance rule broken |
| 4B | Write skew prevented | SERIALIZABLE | Second transaction aborted with SQLSTATE 40001; rule holds |
| 5A | Deadlock | Deadlock detector | One transaction aborted after `deadlock_timeout` (1 s) |
| 5B | Deadlock prevented | Consistent lock ordering | Opposite transfers queue and both succeed |

The full output of every step is in `results/`. Each script ends with a reconciliation check, and after all five demos no account's stored balance differs from its ledger.

## 4. Demo 1: commit, rollback and the ACID properties

A transfer is three statements: insert the transaction row, debit the sender, credit the receiver. If only some of them took effect, money would be created or destroyed.

- **Atomicity.** In 1C the receiver is deliberately credited first, then the debit fails the no-overdraft CHECK. Inside the transaction the credit was visible; after the error PostgreSQL rejects every further statement (`current transaction is aborted`) and turns the final `COMMIT` into a `ROLLBACK`. The credit does not survive.
- **Consistency.** The rules from Portfolio 1 (CHECK constraints, foreign keys, the frozen-account check in `post_ledger_entry`) are what trigger the rollbacks. The database moves from one valid state to another or does not move.
- **Isolation.** Covered in demos 2 to 5.
- **Durability.** In 1F the write-ahead log position is read before and after a commit. With `synchronous_commit = on`, the commit does not return until its WAL record is flushed to disk, so a crash straight afterwards cannot lose it.

**Savepoints (1D).** A batch of three payouts should not fail completely because one receiver's account is frozen. A savepoint before the second payout lets that payout alone be undone, including the debit that had already been taken from the sender for it.

**`transfer_funds()` (1E).** A PL/pgSQL block with an `EXCEPTION` clause is an implicit savepoint. The function uses this: if a business rule fails, the inner block is rolled back and a FAILED row is written instead, so support staff can see the attempt. Serialization failures and deadlocks are deliberately not caught, because the right response to those is for the caller to retry.

## 5. Demo 2: isolation levels

| Level | Dirty read | Non-repeatable read | Phantom | Write skew | Seen in |
|---|---|---|---|---|---|
| READ UNCOMMITTED | Not possible in PostgreSQL | Possible | Possible | Possible | 2A |
| READ COMMITTED (default) | Not possible | Possible | Possible | Possible | 2B |
| REPEATABLE READ | Not possible | Not possible | Not possible in PostgreSQL | Possible | 2C, 2D, 4A |
| SERIALIZABLE | Not possible | Not possible | Not possible | Not possible | 4B |

PostgreSQL uses multi-version concurrency control (MVCC). A reader sees a snapshot made of committed row versions, so readers never block writers and writers never block readers. Two consequences show up in the output:

- READ UNCOMMITTED behaves as READ COMMITTED. In 2A session A asked for READ UNCOMMITTED and still could not see B's uncommitted deposit.
- REPEATABLE READ is stricter than the SQL standard requires: it takes one snapshot for the whole transaction, so phantoms do not appear either (2C).

At READ COMMITTED each statement gets a fresh snapshot. That is why A's second read in 2B shows a different balance and an extra ledger row within one transaction.

In 2D, A holds an old snapshot and then tries to change a row that B has changed and committed since. Under REPEATABLE READ PostgreSQL will not let A write on top of a version it cannot see, and aborts A. The application's job is to retry, which the demo does.

## 6. Demo 3: lost update

Two ATM withdrawals on one account. Both sessions read the balance, each subtracts its own amount in application code, and each writes the result back. The second write replaces the first, so one withdrawal disappears: in the run, 50,000 was paid out but the balance fell by only 20,000.

Three fixes, each suited to a different situation:

| Fix | How it works | Cost | Use when |
|---|---|---|---|
| Pessimistic (3B) | `SELECT ... FOR UPDATE` locks the row at read time | Others wait while the lock is held | Conflicts are common and the transaction is short |
| Optimistic (3C) | Write only if the row still holds the value that was read | Loser must retry | Conflicts are rare, or the user thinks between read and write |
| Atomic (3D) | `SET balance = balance - x` in one statement | None beyond the row lock of the update itself | The new value can be computed in SQL |

In 3B the output shows session B in `pg_stat_activity` with `wait_event_type = Lock` and `pg_blocking_pids` pointing at session A. That is direct evidence of the lock doing its work. LagoonPay's own `post_ledger_entry()` uses the pessimistic and atomic approaches together: it locks the account row, then updates relative to the current balance.

## 7. Demo 4: write skew

Rule: a customer with two accounts must keep a combined balance of at least 6,000,000. Two sessions each check the total, see that a 3,000,000 withdrawal is allowed, and withdraw from **different** accounts.

This is not a lost update. No row is written by both sessions, so row locks and REPEATABLE READ's stale-write check have nothing to object to, and in 4A both commit and the rule is broken. Each decision was correct against its own snapshot; the two together are not equivalent to any one-after-the-other order.

SERIALIZABLE (4B) tracks what each transaction read as well as what it wrote. It detects that the two transactions depend on each other's reads and aborts the second one with `could not serialize access due to read/write dependencies among transactions`. On retry B would see the reduced total and be declined properly.

The cost is that any SERIALIZABLE transaction may be aborted and must be written to retry. An alternative without SERIALIZABLE is to lock a common parent row first (for example the customer row with `FOR UPDATE`), which turns the invisible conflict into an ordinary lock wait.

## 8. Demo 5: deadlock

A locks account 401 and wants 402. B locks 402 and wants 401. Neither can proceed. PostgreSQL waits `deadlock_timeout` (1 second), searches the lock graph, finds the cycle and aborts one transaction; the error names both processes and what each was waiting for. The survivor continues.

Detection is a safety net, not a design. The prevention in 5B is a rule: always lock accounts in ascending `account_id` order, whichever direction the money is going. `transfer_funds()` does this. With the same two opposite transfers, B simply waits for A while holding nothing that A needs, so no cycle can form, and both succeed.

## 9. What LagoonPay would use

- **READ COMMITTED** for ordinary work, with row locks and atomic updates inside `post_ledger_entry()` and `transfer_funds()`. This gives correct balances with the least blocking and no retries for the most common operations.
- **Consistent lock ordering** in every function that touches more than one account.
- **SERIALIZABLE with a retry loop** for the few operations that enforce a rule across several rows, such as a combined-balance or daily-limit check.
- **REPEATABLE READ** for reports and statements that must be internally consistent, such as a reconciliation that reads accounts and ledger entries in several queries.

## 10. How to run

The Portfolio 2 dataset must be loaded first. From inside this folder:

```bash
sh run_all.sh
```

A single demo can be run on its own, for example `psql -d lagoonpay_db -f 03_lost_update_locking.sql` (run `00_setup.sql` once beforehand).

ERROR lines in the output are intended. They are PostgreSQL refusing an overdraft, a frozen account, a stale write, a write skew or a deadlock.

| File | Purpose |
|---|---|
| `00_setup.sql` | `dblink`, and the functions `deposit`, `withdraw`, `transfer_funds`, `reset_balances` |
| `_session_b.sql` | Opens session B; included by demos 2 to 5 |
| `01_commit_rollback.sql` | Commit, rollback, savepoint, durability |
| `02_isolation_levels.sql` | Dirty read, non-repeatable read, phantom, snapshot, stale write |
| `03_lost_update_locking.sql` | Lost update and three fixes |
| `04_serializable_write_skew.sql` | Write skew under REPEATABLE READ and SERIALIZABLE |
| `05_deadlock.sql` | Deadlock detection and prevention |
| `run_all.sh` | Runs everything and writes output to `results/` |
| `results/` | Output of each demo |
| `evidence/` | Screenshots |
