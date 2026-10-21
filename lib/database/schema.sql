-- ============================================================================
-- DRUG STORE MANAGEMENT SYSTEM — MINIMAL SCHEMA
-- PostgreSQL 14+ (Neon or Supabase)
-- ============================================================================
--
-- Tables: users, branches, items, inventory, stock_movements, purchases,
-- purchase_items, sales, sale_items, customers, expenses, suppliers, payments.
--
-- Deliberate choices, so you know why they're there:
--
-- 1. `inventory` is one row per item PER BRANCH PER BATCH, not per item.
--    Same drug, two different expiry dates (your spreadsheet already shows
--    this) = two rows. This is what makes expiry tracking possible at all —
--    collapsing to one row per item would lose the second expiry date.
--
-- 2. `sale_items` exists even though you didn't list it, because a sale is
--    a basket of items, not one item. Without it, a single `sales` row can
--    only hold one drug per transaction — a real POS can't work that way.
--    It's a thin table, doesn't add real complexity.
--a
-- 3. Suppliers get their own table, not just a text field — you're tracking
--    payment_status per purchase (paid/partial/pending), and a text field
--    can't answer "how much do we currently owe this supplier across all
--    invoices." That's a straight SUM(total_amount - amount_paid) once
--    purchases link to a real supplier_id.
--
-- 4. `payments` is a real ledger, not just a running-balance number.
--    `customers.current_balance` and `purchases.amount_paid` are still on
--    those tables as fast-read caches, but they are now maintained
--    AUTOMATICALLY by triggers below, from actual payment rows — never
--    edited directly by the app. Same idea for `sales.total_amount` and
--    `purchases.total_amount`: they're recalculated by trigger from their
--    line items, so they can't silently drift out of sync with reality.
--    This closes the exact gap flagged earlier: every balance on this
--    schema is now backed by a row that explains how it got there.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gives us gen_random_uuid()

CREATE TYPE user_role AS ENUM ('admin', 'manager', 'cashier', 'stock_controller');
CREATE TYPE sale_type AS ENUM ('retail', 'wholesale');
CREATE TYPE payment_method AS ENUM ('cash', 'mobile_money', 'card', 'credit', 'airtel_money', 'tnm_mpamba');
-- 'mobile_money' is legacy (pre Airtel Money / TNM Mpamba split) and is kept
-- so existing rows stay valid. New sales use 'airtel_money' or 'tnm_mpamba'.
CREATE TYPE payment_status AS ENUM ('paid', 'partial', 'pending');

CREATE TYPE stock_movement_type AS ENUM (
    'opening_stock',
    'purchase_in',
    'sale_out',
    'adjustment_out',   -- damaged / lost / expired / negative correction
    'adjustment_in'     -- positive correction / found stock
);

-- ============================================================================
-- BRANCHES & USERS
-- ============================================================================

CREATE TABLE branches (
                          id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                          name        TEXT NOT NULL,          -- e.g. "Mzuzu Branch"
                          location    TEXT,
                          phone       TEXT,
                          is_active   BOOLEAN NOT NULL DEFAULT true,
                          created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
                       id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                       full_name   TEXT NOT NULL,
                       username    TEXT NOT NULL UNIQUE,
                       phone       TEXT,
                       role        user_role NOT NULL,
                       branch_id   UUID REFERENCES branches(id),  -- NULL only for admin
                       is_active   BOOLEAN NOT NULL DEFAULT true,
                       created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
                       CONSTRAINT branch_required_unless_admin
                           CHECK (role = 'admin' OR branch_id IS NOT NULL)
);

-- ============================================================================
-- ITEMS (drugs, gloves, anything the store sells)
-- ============================================================================

CREATE TABLE items (
                       id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                       name                   TEXT NOT NULL,          -- e.g. "AMLODIPINE TABS", "GLOVES (BOX)"
                       category               TEXT,                   -- e.g. "Antibiotics", "Analgesics", "Supplies" — plain text, no lookup table needed
                       unit                   TEXT NOT NULL DEFAULT 'unit', -- tablet, bottle, box, pair...
                       reorder_level          NUMERIC(12,2) NOT NULL DEFAULT 10,
                       requires_prescription  BOOLEAN NOT NULL DEFAULT false,
                       is_active              BOOLEAN NOT NULL DEFAULT true,
                       created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_items_name ON items USING gin (to_tsvector('simple', name));
CREATE INDEX idx_items_category ON items(category);

-- ============================================================================
-- INVENTORY (batch-level stock — see note 1 above)
-- ============================================================================

CREATE TABLE inventory (
                           id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                           item_id             UUID NOT NULL REFERENCES items(id),
                           branch_id           UUID NOT NULL REFERENCES branches(id),
                           batch_number        TEXT,
                           buying_price        NUMERIC(12,2) NOT NULL,
                           retail_price        NUMERIC(12,2) NOT NULL,
                           wholesale_price     NUMERIC(12,2),
                           quantity_received   NUMERIC(12,2) NOT NULL,
                           quantity_available  NUMERIC(12,2) NOT NULL,
                           expiry_date         DATE,
                           received_date       DATE NOT NULL DEFAULT current_date,
                           created_by          UUID REFERENCES users(id),
                           created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
                           CONSTRAINT qty_not_negative CHECK (quantity_available >= 0)
);

CREATE INDEX idx_inventory_branch_item ON inventory(branch_id, item_id);
CREATE INDEX idx_inventory_expiry ON inventory(branch_id, expiry_date)
    WHERE quantity_available > 0;

-- ============================================================================
-- STOCK MOVEMENTS (audit trail — every quantity change writes a row here)
-- ============================================================================

-- inventory_id is NOT NULL: every movement must be traceable to one
-- specific batch (this is what note 1 above depends on for expiry/FEFO
-- to mean anything). reference_table/reference_id remain a soft link
-- (Postgres can't FK to "one of two tables") — that stays app-enforced.
CREATE TABLE stock_movements (
                                 id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                                 branch_id       UUID NOT NULL REFERENCES branches(id),
                                 item_id         UUID NOT NULL REFERENCES items(id),
                                 inventory_id    UUID NOT NULL REFERENCES inventory(id),
                                 movement_type   stock_movement_type NOT NULL,
                                 quantity        NUMERIC(12,2) NOT NULL CHECK (quantity > 0),  -- direction implied by movement_type
                                 reference_table TEXT,                    -- 'sales' or 'purchases'
                                 reference_id    UUID,
                                 notes           TEXT,
                                 performed_by    UUID REFERENCES users(id),
                                 created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_movements_branch_date ON stock_movements(branch_id, created_at);

-- ============================================================================
-- SUPPLIERS
-- ============================================================================

CREATE TABLE suppliers (
                           id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                           name            TEXT NOT NULL,
                           contact_person  TEXT,
                           phone           TEXT,
                           address         TEXT,
                           is_active       BOOLEAN NOT NULL DEFAULT true,
                           created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- PURCHASES (stock coming in)
-- ============================================================================

-- total_amount and amount_paid are cache columns, kept correct by triggers
-- below (from purchase_items and payments respectively) — never write to
-- them directly from application code.
CREATE TABLE purchases (
                           id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                           branch_id       UUID NOT NULL REFERENCES branches(id),
                           supplier_id     UUID REFERENCES suppliers(id),
                           invoice_number  TEXT,
                           payment_status  payment_status NOT NULL DEFAULT 'pending',
                           total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0,
                           amount_paid     NUMERIC(14,2) NOT NULL DEFAULT 0,
                           purchase_date   DATE NOT NULL DEFAULT current_date,
                           created_by      UUID REFERENCES users(id),
                           created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- inventory_id is NOT NULL: every purchase line must create/point to an
-- actual batch — a purchase disconnected from real stock is a data bug,
-- not a valid state.
CREATE TABLE purchase_items (
                                id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                                purchase_id   UUID NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
                                item_id       UUID NOT NULL REFERENCES items(id),
                                inventory_id  UUID NOT NULL REFERENCES inventory(id),  -- the batch this purchase created
                                quantity      NUMERIC(12,2) NOT NULL CHECK (quantity > 0),
                                unit_cost     NUMERIC(12,2) NOT NULL,
                                subtotal      NUMERIC(14,2) NOT NULL
);

-- ============================================================================
-- CUSTOMERS (mainly for credit / debt tracking)
-- ============================================================================

CREATE TABLE customers (
                           id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                           branch_id        UUID REFERENCES branches(id),
                           name             TEXT NOT NULL,
                           phone            TEXT,
                           current_balance  NUMERIC(12,2) NOT NULL DEFAULT 0,  -- what they owe
                           created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- SALES (stock going out — see note 2 above for why sale_items exists)
-- ============================================================================

-- total_amount and amount_paid are cache columns, kept correct by triggers
-- below (from sale_items and payments respectively) — never write to them
-- directly from application code.
CREATE TABLE sales (
                       id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                       branch_id       UUID NOT NULL REFERENCES branches(id),
                       customer_id     UUID REFERENCES customers(id),
                       cashier_id      UUID NOT NULL REFERENCES users(id),
                       sale_type       sale_type NOT NULL DEFAULT 'retail',
                       payment_method  payment_method NOT NULL,
                       payment_status  payment_status NOT NULL DEFAULT 'paid',
                       total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0,
                       amount_paid     NUMERIC(14,2) NOT NULL DEFAULT 0,
                       receipt_number  TEXT UNIQUE,
                       sale_date       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sales_branch_date ON sales(branch_id, sale_date);

CREATE TABLE sale_items (
                            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                            sale_id       UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
                            item_id       UUID NOT NULL REFERENCES items(id),
                            inventory_id  UUID NOT NULL REFERENCES inventory(id), -- which batch was drawn (FEFO)
                            quantity      NUMERIC(12,2) NOT NULL CHECK (quantity > 0),
                            unit_price    NUMERIC(12,2) NOT NULL,   -- retail or wholesale price charged
                            unit_cost     NUMERIC(12,2) NOT NULL,   -- copied from inventory.buying_price at sale time
                            subtotal      NUMERIC(14,2) NOT NULL,
                            profit        NUMERIC(14,2) GENERATED ALWAYS AS ((unit_price - unit_cost) * quantity) STORED
);

-- ============================================================================
-- EXPENSES (needed for real net-profit numbers — see note in chat)
-- ============================================================================

CREATE TABLE expenses (
                          id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                          branch_id     UUID NOT NULL REFERENCES branches(id),
                          category      TEXT NOT NULL,   -- 'Transport', 'Electricity', 'Rent', 'Salaries', 'Internet', 'Repairs', 'Other'
                          amount        NUMERIC(12,2) NOT NULL,
                          description   TEXT,
                          expense_date  DATE NOT NULL DEFAULT current_date,
                          recorded_by   UUID REFERENCES users(id),
                          created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- PAYMENTS (the ledger behind customer debt and supplier balances)
-- ============================================================================
--
-- Exactly one of (customer_id, supplier_id) is set per row — a payment is
-- either money coming IN from a customer paying down credit, or money
-- going OUT to a supplier paying down an invoice. sale_id / purchase_id
-- link it to the specific transaction being paid down where relevant.

CREATE TABLE payments (
                          id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                          branch_id       UUID NOT NULL REFERENCES branches(id),
                          customer_id     UUID REFERENCES customers(id),
                          sale_id         UUID REFERENCES sales(id),       -- optional: which sale this pays down
                          supplier_id     UUID REFERENCES suppliers(id),
                          purchase_id     UUID REFERENCES purchases(id),   -- optional: which invoice this pays down
                          amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
                          payment_method  payment_method NOT NULL,
                          payment_date    TIMESTAMPTZ NOT NULL DEFAULT now(),
                          recorded_by     UUID REFERENCES users(id),
                          notes           TEXT,
                          CONSTRAINT exactly_one_party CHECK (
                              (customer_id IS NOT NULL AND supplier_id IS NULL) OR
                              (supplier_id IS NOT NULL AND customer_id IS NULL)
                              )
);

CREATE INDEX idx_payments_customer ON payments(customer_id);
CREATE INDEX idx_payments_supplier ON payments(supplier_id);

-- ============================================================================
-- TRIGGERS — keep every cache column correct automatically. The app only
-- ever INSERTs into payments / sale_items / purchase_items; it never
-- touches customers.current_balance, purchases.amount_paid/total_amount,
-- or sales.total_amount directly.
-- ============================================================================

-- Customer pays down credit -> reduce their balance.
-- Supplier gets paid -> increase amount_paid on that purchase invoice.
CREATE FUNCTION fn_apply_payment() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.customer_id IS NOT NULL THEN
UPDATE customers SET current_balance = current_balance - NEW.amount
WHERE id = NEW.customer_id;
END IF;
    IF NEW.purchase_id IS NOT NULL THEN
UPDATE purchases SET amount_paid = amount_paid + NEW.amount
WHERE id = NEW.purchase_id;
END IF;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_payment
    AFTER INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_apply_payment();

-- A credit sale increases customer debt by (total_amount - amount_paid).
-- This fires on INSERT *and* on UPDATE OF total_amount, because total_amount
-- starts at 0 and is only filled in afterwards by fn_recalc_sale_total once
-- sale_items exist (a sale's header is created before its line items).
-- Using a before/after delta (rather than reading NEW.total_amount alone)
-- makes this correct regardless of that ordering, and safe to fire more
-- than once as line items are added one at a time.
CREATE FUNCTION fn_apply_credit_sale() RETURNS TRIGGER AS $$
DECLARE
old_debt NUMERIC := COALESCE(OLD.total_amount, 0) - COALESCE(OLD.amount_paid, 0);
    new_debt NUMERIC := COALESCE(NEW.total_amount, 0) - COALESCE(NEW.amount_paid, 0);
BEGIN
    IF NEW.customer_id IS NOT NULL AND NEW.payment_method = 'credit' THEN
UPDATE customers SET current_balance = current_balance + (new_debt - old_debt)
WHERE id = NEW.customer_id;
END IF;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_credit_sale
    AFTER INSERT OR UPDATE OF total_amount, amount_paid ON sales
    FOR EACH ROW EXECUTE FUNCTION fn_apply_credit_sale();

-- Keep sales.total_amount in sync with its line items automatically.
CREATE FUNCTION fn_recalc_sale_total() RETURNS TRIGGER AS $$
DECLARE
target_sale_id UUID := COALESCE(NEW.sale_id, OLD.sale_id);
BEGIN
UPDATE sales SET total_amount = (
    SELECT COALESCE(SUM(subtotal), 0) FROM sale_items WHERE sale_id = target_sale_id
) WHERE id = target_sale_id;
RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_recalc_sale_total
    AFTER INSERT OR UPDATE OR DELETE ON sale_items
    FOR EACH ROW EXECUTE FUNCTION fn_recalc_sale_total();

-- Keep purchases.total_amount in sync with its line items automatically.
CREATE FUNCTION fn_recalc_purchase_total() RETURNS TRIGGER AS $$
DECLARE
target_purchase_id UUID := COALESCE(NEW.purchase_id, OLD.purchase_id);
BEGIN
UPDATE purchases SET total_amount = (
    SELECT COALESCE(SUM(subtotal), 0) FROM purchase_items WHERE purchase_id = target_purchase_id
) WHERE id = target_purchase_id;
RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_recalc_purchase_total
    AFTER INSERT OR UPDATE OR DELETE ON purchase_items
    FOR EACH ROW EXECUTE FUNCTION fn_recalc_purchase_total();

-- ============================================================================
-- DASHBOARD VIEWS — query these directly, don't recompute in app code
-- ============================================================================

-- Live stock per item per branch, summed across its batches
CREATE VIEW v_current_stock AS
SELECT
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    i.reorder_level,
    SUM(inv.quantity_available) AS quantity_on_hand
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
GROUP BY inv.branch_id, inv.item_id, i.name, i.reorder_level;

-- Sellable stock follows the same FEFO rule as create_sale: expired batches
-- never contribute to availability, and the first batch supplies the display
-- prices/next expiry. Keep buying prices out of this cashier-facing view.
CREATE VIEW v_sellable_stock WITH (security_invoker = true) AS
WITH sellable_batches AS (
    SELECT
        inv.branch_id,
        inv.item_id,
        inv.quantity_available,
        inv.expiry_date,
        inv.retail_price,
        inv.wholesale_price,
        row_number() OVER (
            PARTITION BY inv.branch_id, inv.item_id
            ORDER BY inv.expiry_date ASC NULLS LAST, inv.received_date ASC, inv.created_at ASC
        ) AS batch_rank
    FROM inventory inv
    WHERE inv.quantity_available > 0
      AND (inv.expiry_date IS NULL OR inv.expiry_date >= current_date)
)
SELECT
    b.branch_id,
    b.item_id,
    i.name AS item_name,
    i.category,
    i.unit,
    i.reorder_level,
    i.requires_prescription,
    SUM(b.quantity_available) AS sellable_quantity,
    MAX(b.expiry_date) FILTER (WHERE b.batch_rank = 1) AS next_expiry_date,
    MAX(b.retail_price) FILTER (WHERE b.batch_rank = 1) AS retail_price,
    MAX(b.wholesale_price) FILTER (WHERE b.batch_rank = 1) AS wholesale_price
FROM sellable_batches b
JOIN items i ON i.id = b.item_id
WHERE i.is_active
GROUP BY b.branch_id, b.item_id, i.name, i.category, i.unit,
         i.reorder_level, i.requires_prescription;

-- Low stock, needs reorder
CREATE VIEW v_low_stock AS
SELECT * FROM v_current_stock WHERE quantity_on_hand <= reorder_level;

-- Expiring within 90 days
CREATE VIEW v_expiring_soon AS
SELECT
    inv.id AS inventory_id,
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    inv.quantity_available,
    inv.expiry_date,
    (inv.expiry_date - current_date) AS days_to_expiry
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
WHERE inv.quantity_available > 0
  AND inv.expiry_date IS NOT NULL
  AND inv.expiry_date <= current_date + INTERVAL '90 days'
        ORDER BY inv.expiry_date ASC;

-- Today's sales per branch
CREATE VIEW v_today_sales AS
SELECT branch_id, COUNT(*) AS transaction_count, SUM(total_amount) AS total_sales
FROM sales
WHERE sale_date::date = current_date
GROUP BY branch_id;

-- Realised profit per branch per day
CREATE VIEW v_daily_profit AS
SELECT
    s.branch_id,
    s.sale_date::date AS sale_day,
    SUM(si.subtotal) AS revenue,
    SUM(si.unit_cost * si.quantity) AS cost_of_goods,
    SUM(si.profit) AS gross_profit
FROM sales s
         JOIN sale_items si ON si.sale_id = s.id
GROUP BY s.branch_id, s.sale_date::date;

-- Potential profit still on the shelf right now
CREATE VIEW v_expected_profit_from_stock AS
SELECT branch_id, SUM(quantity_available * (retail_price - buying_price)) AS potential_profit
FROM inventory
GROUP BY branch_id;

-- Net profit = realised gross profit to date minus expenses to date
CREATE VIEW v_branch_financial_summary AS
SELECT
    b.id AS branch_id,
    b.name AS branch_name,
    COALESCE(p.total_gross_profit, 0) AS total_gross_profit,
    COALESCE(e.total_expenses, 0) AS total_expenses,
    COALESCE(p.total_gross_profit, 0) - COALESCE(e.total_expenses, 0) AS net_profit
FROM branches b
         LEFT JOIN (SELECT branch_id, SUM(gross_profit) AS total_gross_profit FROM v_daily_profit GROUP BY branch_id) p
                   ON p.branch_id = b.id
         LEFT JOIN (SELECT branch_id, SUM(amount) AS total_expenses FROM expenses GROUP BY branch_id) e
                   ON e.branch_id = b.id;

-- Best-selling items (admin overview across all branches; filter by
-- branch_id in your query for a single store's view)
CREATE VIEW v_best_selling_items AS
SELECT
    si.item_id,
    i.name AS item_name,
    s.branch_id,
    SUM(si.quantity) AS total_quantity_sold,
    SUM(si.subtotal) AS total_revenue,
    SUM(si.profit) AS total_profit
FROM sale_items si
         JOIN sales s ON s.id = si.sale_id
         JOIN items i ON i.id = si.item_id
GROUP BY si.item_id, i.name, s.branch_id;

-- Outstanding customer debts
CREATE VIEW v_customer_debts AS
SELECT id AS customer_id, name, branch_id, current_balance
FROM customers
WHERE current_balance > 0;

-- Outstanding balances owed TO suppliers, across all their invoices
CREATE VIEW v_supplier_balances AS
SELECT
    s.id AS supplier_id,
    s.name AS supplier_name,
    SUM(p.total_amount - p.amount_paid) AS amount_owed
FROM suppliers s
         JOIN purchases p ON p.supplier_id = s.id
WHERE p.payment_status <> 'paid'
GROUP BY s.id, s.name
HAVING SUM(p.total_amount - p.amount_paid) > 0;

-- Full payment history for a customer (or filter by customer_id in your query)
CREATE VIEW v_customer_payment_history AS
SELECT id AS payment_id, customer_id, sale_id, branch_id, amount, payment_method, payment_date, recorded_by
FROM payments
WHERE customer_id IS NOT NULL
ORDER BY payment_date DESC;

-- Full payment history to a supplier
CREATE VIEW v_supplier_payment_history AS
SELECT id AS payment_id, supplier_id, purchase_id, branch_id, amount, payment_method, payment_date, recorded_by
FROM payments
WHERE supplier_id IS NOT NULL
ORDER BY payment_date DESC;


-- ============================================================================
-- LINK SUPABASE AUTH TO public.users
-- ============================================================================
-- Run this after your main schema. It does NOT replace the users table,
-- it wires it up to Supabase Auth so the two stay in sync automatically.

-- 1. users.id must be driven by the auth account, not generated on its own.
ALTER TABLE users ALTER COLUMN id DROP DEFAULT;
ALTER TABLE users
    ADD CONSTRAINT users_id_fkey_auth
        FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- 2. Add email so the client can read it without touching the auth schema
--    (the client API is not allowed to SELECT from auth.users directly).
ALTER TABLE users ADD COLUMN email TEXT;
UPDATE users SET email = '' WHERE email IS NULL; -- backfill any existing rows
ALTER TABLE users ALTER COLUMN email SET NOT NULL;

-- ============================================================================
-- 3. Auto-create the matching `users` row whenever someone signs up through
--    Supabase Auth. full_name / username come from the metadata you pass
--    into auth.signUp(data: {...}) on the Flutter side (see auth_repository.dart).
--
--    Username falls back to the email prefix + a slice of the user's own id,
--    so it still satisfies the UNIQUE constraint even if two people share an
--    email prefix (e.g. two "mable@" addresses at different domains).
-- ============================================================================
CREATE FUNCTION handle_new_auth_user() RETURNS TRIGGER AS $$
BEGIN
INSERT INTO public.users (id, email, full_name, username, role)
VALUES (
           NEW.id,
           NEW.email,
           COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
           COALESCE(
                   NEW.raw_user_meta_data->>'username',
            split_part(NEW.email, '@', 1) || '_' || substr(NEW.id::text, 1, 4)
        ),
           'cashier' -- default role; an admin reassigns it afterwards
       );
RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION handle_new_auth_user();

-- ============================================================================
-- 4. Row Level Security — staff can read their own row; admins can read
--    and update everyone's. Adjust branch scoping later if a manager should
--    only see their own branch's staff.
-- ============================================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own profile"
    ON users FOR SELECT
                            USING (auth.uid() = id);

CREATE POLICY "Admins can view all profiles"
    ON users FOR SELECT
                            USING (
                            EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
                            );

CREATE POLICY "Admins can update any profile"
    ON users FOR UPDATE
                            USING (
                            EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
                            );

-- ============================================================================
-- PENDING-APPROVAL SIGNUP FLOW
-- Run after your main schema + auth_integration.sql.
--
-- Anyone can create an account. New accounts land with is_active = false,
-- a placeholder role, and no branch. They cannot meaningfully use the app
-- until an admin assigns a real role + branch and flips is_active = true
-- (see AuthRepository.approveUser on the Flutter side).
-- ============================================================================

-- 1. The original constraint required a branch for every non-admin user,
--    which blocked signup entirely since new users have no branch yet.
--    Relax it: a branch is only required once the account is active.
ALTER TABLE users DROP CONSTRAINT branch_required_unless_admin;
ALTER TABLE users ADD CONSTRAINT branch_required_unless_admin
    CHECK (role = 'admin' OR is_active = false OR branch_id IS NOT NULL);

-- 2. New signups now start inactive. 'cashier' is just a placeholder role
--    until an admin assigns the real one on approval — it has no effect
--    on access, since is_active = false blocks login regardless of role.
CREATE OR REPLACE FUNCTION handle_new_auth_user() RETURNS TRIGGER AS $$
BEGIN
INSERT INTO public.users (id, email, full_name, username, role, is_active)
VALUES (
           NEW.id,
           NEW.email,
           COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
           COALESCE(
                   NEW.raw_user_meta_data->>'username',
            split_part(NEW.email, '@', 1) || '_' || substr(NEW.id::text, 1, 4)
        ),
           'cashier',
           false
       );
RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Fast lookup for an admin's "pending approvals" screen.
CREATE INDEX IF NOT EXISTS idx_users_pending ON users(is_active) WHERE is_active = false;

-- Existing RLS policies already cover this flow with no changes needed:
--   "Admins can view all profiles"  -> lets an admin list pending users
--   "Admins can update any profile" -> lets an admin set role/branch_id/is_active

-- ============================================================================
-- FIX: infinite recursion in RLS policies on `users`
--
-- The original "Admins can view/update all profiles" policies checked
-- role = 'admin' via a subquery on `users` itself. Every row-level check
-- on `users` re-triggers those same policies, which query `users` again,
-- forever. Postgres detects this and errors with 42P17.
--
-- Fix: do the admin check inside a SECURITY DEFINER function. It runs
-- with the function owner's privileges (normally the table owner), which
-- bypasses RLS on its own internal query — so it can safely check
-- "is this user an admin?" without re-entering the policy that's asking.
-- ============================================================================

CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
SELECT EXISTS (
    SELECT 1 FROM users WHERE id = auth.uid() AND role = 'admin'
);
$$;

DROP POLICY IF EXISTS "Admins can view all profiles" ON users;
CREATE POLICY "Admins can view all profiles"
    ON users FOR SELECT
                                 USING (is_admin());

DROP POLICY IF EXISTS "Admins can update any profile" ON users;
CREATE POLICY "Admins can update any profile"
    ON users FOR UPDATE
                                 USING (is_admin());

-- "Users can view their own profile" is untouched — it only checks
-- auth.uid() = id, no self-referencing subquery, so it was never the
-- source of the recursion.
CREATE OR REPLACE FUNCTION fn_apply_payment() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.customer_id IS NOT NULL THEN
UPDATE customers SET current_balance = current_balance - NEW.amount
WHERE id = NEW.customer_id;
END IF;

    IF NEW.sale_id IS NOT NULL THEN
UPDATE sales
SET amount_paid = amount_paid + NEW.amount,
    payment_status = CASE
                         WHEN amount_paid + NEW.amount >= total_amount THEN 'paid'
                         WHEN amount_paid + NEW.amount > 0 THEN 'partial'
                         ELSE 'pending'
        END
WHERE id = NEW.sale_id;
END IF;

    IF NEW.purchase_id IS NOT NULL THEN
UPDATE purchases SET amount_paid = amount_paid + NEW.amount
WHERE id = NEW.purchase_id;
END IF;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FIX 1 — RLS: give admins (and branch staff) read access to the tables
-- the dashboard actually queries.
--
-- Run after your main schema + auth_integration.sql (this reuses is_admin()
-- from there).
--
-- Why this fixes the "empty dashboard" problem: v_low_stock and
-- v_expiring_soon are views, and views don't carry their own RLS policies.
-- Postgres enforces RLS by checking policies on the underlying TABLES
-- (inventory, items, branches, sales), evaluated as the querying user via
-- auth.uid() — not the view owner. So branches, inventory and sales having
-- no policies at all meant every query against them (views included) was
-- silently filtered down to zero rows once RLS is enabled on a table with
-- no matching policy — that's the default-deny behavior.
--
-- Scope of this fix: branches, items, inventory, sales, sale_items — what
-- the current admin dashboard needs. Staff also get branch-scoped access
-- (a cashier at Blantyre shouldn't see Mzuzu's sales) since you'll need
-- that regardless once staff screens start querying these tables. If you
-- later want the same pattern on purchases, payments, customers, expenses,
-- stock_movements and suppliers, it's a straightforward copy of the
-- "sales" block below with the table name swapped in — say the word and
-- I'll write that migration too.
-- ============================================================================

-- Helper: the branch_id of the currently authenticated user (NULL for
-- admins, who aren't tied to one branch).
CREATE OR REPLACE FUNCTION user_branch_id() RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
SELECT branch_id FROM users WHERE id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- BRANCHES — reference data every signed-in, active user needs (for the
-- filter dropdown, branch names on receipts, etc). Only admins edit it.
-- ---------------------------------------------------------------------------
ALTER TABLE branches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can view branches"
    ON branches FOR SELECT
                               USING (auth.uid() IS NOT NULL);

CREATE POLICY "Admins manage branches"
    ON branches FOR ALL
    USING (is_admin())
    WITH CHECK (is_admin());

-- ---------------------------------------------------------------------------
-- ITEMS — the drug catalogue, same treatment as branches.
-- ---------------------------------------------------------------------------
ALTER TABLE items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can view items"
    ON items FOR SELECT
                            USING (auth.uid() IS NOT NULL);

CREATE POLICY "Admins manage items"
    ON items FOR ALL
    USING (is_admin())
    WITH CHECK (is_admin());

-- ---------------------------------------------------------------------------
-- INVENTORY — batch-level stock. Admins see every branch; staff see only
-- their own. v_current_stock, v_low_stock and v_expiring_soon are all built
-- on this table, so these two policies cover all three views at once.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins view all inventory"
    ON inventory FOR SELECT
                                USING (is_admin());

CREATE POLICY "Staff view own branch inventory"
    ON inventory FOR SELECT
                                USING (branch_id = user_branch_id());

CREATE POLICY "Admins and staff manage own branch inventory"
    ON inventory FOR ALL
    USING (is_admin() OR branch_id = user_branch_id())
    WITH CHECK (is_admin() OR branch_id = user_branch_id());

-- ---------------------------------------------------------------------------
-- SALES — admins see every branch; staff see and record only their own.
-- v_today_sales is built on this table, so it inherits these policies too.
-- ---------------------------------------------------------------------------
ALTER TABLE sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins view all sales"
    ON sales FOR SELECT
                            USING (is_admin());

CREATE POLICY "Staff view own branch sales"
    ON sales FOR SELECT
                            USING (branch_id = user_branch_id());

CREATE POLICY "Staff record sales at own branch"
    ON sales FOR INSERT
    WITH CHECK (is_admin() OR branch_id = user_branch_id());

CREATE POLICY "Admins update any sale"
    ON sales FOR UPDATE
                                   USING (is_admin())
                 WITH CHECK (is_admin());

-- sale_items has no branch_id of its own — access follows the parent sale.
ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View sale_items via parent sale access"
    ON sale_items FOR SELECT
                                 USING (
                                 EXISTS (
                                 SELECT 1 FROM sales s
                                 WHERE s.id = sale_items.sale_id
                                 AND (is_admin() OR s.branch_id = user_branch_id())
                                 )
                                 );

CREATE POLICY "Insert sale_items via parent sale access"
    ON sale_items FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM sales s
            WHERE s.id = sale_items.sale_id
              AND (is_admin() OR s.branch_id = user_branch_id())
        )
    );

-- ============================================================================
-- FIX 2 — views carry branch_name directly, so the app doesn't need to
-- join against `branches` in Dart just to label a row.
--
-- branch_name is appended as the LAST column in each view (rather than
-- inserted where it reads naturally) so this is a safe CREATE OR REPLACE —
-- Postgres requires existing columns to keep their name/position/type in a
-- replaced view; new columns can only be added at the end.
-- ============================================================================

CREATE OR REPLACE VIEW v_current_stock AS
SELECT
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    i.reorder_level,
    SUM(inv.quantity_available) AS quantity_on_hand,
    b.name AS branch_name
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
         JOIN branches b ON b.id = inv.branch_id
GROUP BY inv.branch_id, inv.item_id, i.name, i.reorder_level, b.name;

-- v_low_stock is SELECT * from v_current_stock, so it picks up branch_name
-- automatically — no change needed, but re-stating it keeps this file
-- runnable top-to-bottom even if v_low_stock didn't exist yet.
CREATE OR REPLACE VIEW v_low_stock AS
SELECT * FROM v_current_stock WHERE quantity_on_hand <= reorder_level;

CREATE OR REPLACE VIEW v_expiring_soon AS
SELECT
    inv.id AS inventory_id,
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    inv.quantity_available,
    inv.expiry_date,
    (inv.expiry_date - current_date) AS days_to_expiry,
    b.name AS branch_name
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
         JOIN branches b ON b.id = inv.branch_id
WHERE inv.quantity_available > 0
  AND inv.expiry_date IS NOT NULL
  AND inv.expiry_date <= current_date + INTERVAL '90 days'
ORDER BY inv.expiry_date ASC;

-- ============================================================================
-- ADMIN MANAGEMENT — run once in the Supabase SQL editor, after your existing
-- schema + dashboard_rls_and_views.sql (this reuses is_admin()).
--
-- What already works without this file (existing RLS policies):
--   * create / edit / activate / deactivate branches   ("Admins manage branches")
--   * assign a user to a branch, remove them from one  ("Admins can update any profile")
--
-- What needs this file:
--   * deleting a branch   -> admin_delete_branch()
--   * deleting a user     -> admin_delete_user()
--     (the client API can't touch auth.users, so this runs server-side)
--
-- Both functions check is_admin() themselves, so a non-admin calling them gets
-- an error even though they are SECURITY DEFINER.
--
-- Deleting is refused when the row is referenced by real history (sales,
-- stock, payments...). Postgres raises a foreign-key error, the function
-- turns it into a readable message, and the whole operation rolls back —
-- nobody is left half-unassigned.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin_delete_branch(p_branch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only admins can delete branches.';
END IF;

    -- Free the staff first. Non-admins are deactivated (the schema requires a
    -- branch for any active non-admin); admins just lose the link.
UPDATE users
SET branch_id = NULL,
    is_active = CASE WHEN role = 'admin' THEN is_active ELSE false END
WHERE branch_id = p_branch_id;

DELETE FROM branches WHERE id = p_branch_id;

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'This branch has stock, sales or other records and can''t be deleted. Deactivate it instead.';
END;
$$;

CREATE OR REPLACE FUNCTION admin_delete_user(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only admins can delete users.';
END IF;

    IF p_user_id = auth.uid() THEN
        RAISE EXCEPTION 'You can''t delete your own account.';
END IF;

    -- public.users.id references auth.users(id) ON DELETE CASCADE, so removing
    -- the auth account removes the profile row too.
DELETE FROM auth.users WHERE id = p_user_id;

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'This user has recorded sales, stock or payment activity, so the account can''t be deleted. Remove them from their branch instead.';
END;
$$;

-- Only signed-in users may call these (and they still must pass is_admin()).
REVOKE ALL ON FUNCTION admin_delete_branch(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION admin_delete_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_delete_branch(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_user(uuid) TO authenticated;


ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins view all expenses" ON expenses FOR SELECT USING (is_admin());
CREATE POLICY "Staff view own branch expenses" ON expenses FOR SELECT USING (branch_id = user_branch_id());
-- ============================================================================
-- ADMIN INVENTORY PREP
-- Needs Postgres 15+ (Supabase has it) for security_invoker views.
-- ============================================================================

-- Helper: role of the signed-in user (SECURITY DEFINER avoids RLS recursion)
CREATE OR REPLACE FUNCTION user_role_name() RETURNS user_role
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public
AS $$ SELECT role FROM users WHERE id = auth.uid(); $$;

-- ----------------------------------------------------------------------------
-- 0. Trigger functions must bypass RLS. They run as the caller, so once RLS is
--    on, a cashier's sale_items insert could not update sales.total_amount
--    (blocked silently), and a stock controller's purchase_items insert could
--    not update purchases.total_amount.
-- ----------------------------------------------------------------------------
ALTER FUNCTION fn_recalc_sale_total()     SECURITY DEFINER SET search_path = public;
ALTER FUNCTION fn_recalc_purchase_total() SECURITY DEFINER SET search_path = public;
ALTER FUNCTION fn_apply_credit_sale()     SECURITY DEFINER SET search_path = public;
ALTER FUNCTION fn_apply_payment()         SECURITY DEFINER SET search_path = public;

-- ----------------------------------------------------------------------------
-- 1. Make every view respect the caller's RLS (otherwise views run as their
--    owner and skip branch isolation).
-- ----------------------------------------------------------------------------
ALTER VIEW v_current_stock              SET (security_invoker = true);
ALTER VIEW v_low_stock                  SET (security_invoker = true);
ALTER VIEW v_today_sales                SET (security_invoker = true);
ALTER VIEW v_daily_profit               SET (security_invoker = true);
ALTER VIEW v_expected_profit_from_stock SET (security_invoker = true);
ALTER VIEW v_branch_financial_summary   SET (security_invoker = true);
ALTER VIEW v_best_selling_items         SET (security_invoker = true);
ALTER VIEW v_customer_debts             SET (security_invoker = true);
ALTER VIEW v_supplier_balances          SET (security_invoker = true);
ALTER VIEW v_customer_payment_history   SET (security_invoker = true);
ALTER VIEW v_supplier_payment_history   SET (security_invoker = true);

-- ----------------------------------------------------------------------------
-- 2. Stock value per branch (cost value, retail value, potential profit)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stock_value WITH (security_invoker = true) AS
SELECT
    inv.branch_id,
    b.name AS branch_name,
    SUM(inv.quantity_available * inv.buying_price) AS stock_value_at_cost,
    SUM(inv.quantity_available * inv.retail_price) AS stock_value_at_retail,
    SUM(inv.quantity_available * (inv.retail_price - inv.buying_price)) AS potential_profit
FROM inventory inv
         JOIN branches b ON b.id = inv.branch_id
WHERE inv.quantity_available > 0
GROUP BY inv.branch_id, b.name;

-- ----------------------------------------------------------------------------
-- 3. Separate expired from expiring-soon
--    (new columns are appended at the end so CREATE OR REPLACE is allowed)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_expiring_soon WITH (security_invoker = true) AS
SELECT
    inv.id AS inventory_id,
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    inv.quantity_available,
    inv.expiry_date,
    (inv.expiry_date - current_date) AS days_to_expiry,
    b.name AS branch_name,
    (inv.quantity_available * inv.buying_price) AS cost_value,
    inv.batch_number
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
         JOIN branches b ON b.id = inv.branch_id
WHERE inv.quantity_available > 0
  AND inv.expiry_date IS NOT NULL
  AND inv.expiry_date >= current_date                        -- NOT yet expired
  AND inv.expiry_date <= current_date + INTERVAL '90 days'
ORDER BY inv.expiry_date ASC;

CREATE OR REPLACE VIEW v_expired_stock WITH (security_invoker = true) AS
SELECT
    inv.id AS inventory_id,
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    inv.quantity_available,
    inv.expiry_date,
    (current_date - inv.expiry_date) AS days_expired,
    b.name AS branch_name,
    (inv.quantity_available * inv.buying_price) AS cost_value,
    inv.batch_number
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
         JOIN branches b ON b.id = inv.branch_id
WHERE inv.quantity_available > 0
  AND inv.expiry_date IS NOT NULL
  AND inv.expiry_date < current_date
ORDER BY inv.expiry_date ASC;

-- ----------------------------------------------------------------------------
-- 4. Movements with readable names (for the audit-trail tab)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stock_movements_detail WITH (security_invoker = true) AS
SELECT
    m.id AS movement_id,
    m.created_at,
    m.branch_id,
    b.name AS branch_name,
    m.item_id,
    i.name AS item_name,
    m.inventory_id,
    inv.batch_number,
    m.movement_type,
    m.quantity,
    m.reference_table,
    m.reference_id,
    m.notes,
    m.performed_by,
    u.full_name AS performed_by_name
FROM stock_movements m
         JOIN branches b ON b.id = m.branch_id
         JOIN items i ON i.id = m.item_id
         JOIN inventory inv ON inv.id = m.inventory_id
         LEFT JOIN users u ON u.id = m.performed_by
ORDER BY m.created_at DESC;

-- ----------------------------------------------------------------------------
-- 5. RLS: stock_movements (append-only audit trail: no update/delete policies)
-- ----------------------------------------------------------------------------
ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View movements: admin all, staff own branch"
    ON stock_movements FOR SELECT
                                      USING (is_admin() OR branch_id = user_branch_id());

CREATE POLICY "Record movements: admin all, staff own branch"
    ON stock_movements FOR INSERT
    WITH CHECK (is_admin() OR branch_id = user_branch_id());

-- ----------------------------------------------------------------------------
-- 6. RLS: purchases + purchase_items
--    Admin: everything. Manager / stock controller: own branch only.
--    Cashiers can view but not create purchases.
-- ----------------------------------------------------------------------------
ALTER TABLE purchases ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View purchases: admin all, staff own branch"
    ON purchases FOR SELECT
                                USING (is_admin() OR branch_id = user_branch_id());

CREATE POLICY "Create purchases: admin, or manager/stock controller at own branch"
    ON purchases FOR INSERT
    WITH CHECK (
        is_admin()
        OR (branch_id = user_branch_id()
            AND user_role_name() IN ('manager', 'stock_controller'))
    );

CREATE POLICY "Admins update purchases"
    ON purchases FOR UPDATE
                                       USING (is_admin()) WITH CHECK (is_admin());

ALTER TABLE purchase_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View purchase_items via parent purchase"
    ON purchase_items FOR SELECT
                                     USING (EXISTS (
                                     SELECT 1 FROM purchases p
                                     WHERE p.id = purchase_items.purchase_id
                                     AND (is_admin() OR p.branch_id = user_branch_id())
                                     ));

CREATE POLICY "Insert purchase_items via parent purchase"
    ON purchase_items FOR INSERT
    WITH CHECK (EXISTS (
        SELECT 1 FROM purchases p
        WHERE p.id = purchase_items.purchase_id
          AND (is_admin()
               OR (p.branch_id = user_branch_id()
                   AND user_role_name() IN ('manager', 'stock_controller')))
    ));

-- ----------------------------------------------------------------------------
-- 7. RLS: suppliers (shared business-wide, like items)
-- ----------------------------------------------------------------------------
ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users view suppliers"
    ON suppliers FOR SELECT
                                USING (auth.uid() IS NOT NULL);

CREATE POLICY "Admins manage suppliers"
    ON suppliers FOR ALL
    USING (is_admin()) WITH CHECK (is_admin());


       -- ============================================================================
-- REPORTS PREP: RLS for expenses / payments / customers + date-range functions
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_expenses_branch_date ON expenses(branch_id, expense_date);

-- ----------------------------------------------------------------------------
-- 1. EXPENSES: admin sees all; branch staff see and record their own branch.
--    Branch staff (cashier, stock controller, manager) see and record
--    their own branch only.
-- ----------------------------------------------------------------------------
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View expenses: admin all, manager own branch"
    ON expenses FOR SELECT
                               USING (is_admin() OR (branch_id = user_branch_id() AND user_role_name() = 'manager'));

CREATE POLICY "Record expenses: admin all, manager own branch"
    ON expenses FOR INSERT
    WITH CHECK (is_admin() OR (branch_id = user_branch_id() AND user_role_name() = 'manager'));

CREATE POLICY "Admins update expenses" ON expenses FOR UPDATE
                                                                  USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "Admins delete expenses" ON expenses FOR DELETE
USING (is_admin());

-- ----------------------------------------------------------------------------
-- 2. PAYMENTS (ledger: insert only, no update/delete policies for anyone)
--    Customer payments: cashier/manager at own branch.
--    Supplier payments: manager at own branch (stock controllers can view).
-- ----------------------------------------------------------------------------
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View payments: admin all, staff own branch"
    ON payments FOR SELECT
                               USING (
                               is_admin()
                               OR (branch_id = user_branch_id()
                               AND (customer_id IS NOT NULL
                               OR user_role_name() IN ('manager', 'stock_controller')))
                               );

CREATE POLICY "Record payments: admin all, staff own branch by role"
    ON payments FOR INSERT
    WITH CHECK (
        is_admin()
        OR (branch_id = user_branch_id()
            AND ((customer_id IS NOT NULL AND user_role_name() IN ('cashier', 'manager'))
              OR (supplier_id IS NOT NULL AND user_role_name() = 'manager')))
    );

-- ----------------------------------------------------------------------------
-- 3. CUSTOMERS: admin sees all; staff see their own branch's customers.
--    Customers with no branch are visible to admin only.
-- ----------------------------------------------------------------------------
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View customers: admin all, staff own branch"
    ON customers FOR SELECT
                                USING (is_admin() OR branch_id = user_branch_id());

CREATE POLICY "Add customers: admin, or cashier/manager at own branch"
    ON customers FOR INSERT
    WITH CHECK (is_admin()
        OR (branch_id = user_branch_id() AND user_role_name() IN ('cashier', 'manager')));

CREATE POLICY "Edit customers: admin, or manager at own branch"
    ON customers FOR UPDATE
                                       USING (is_admin() OR (branch_id = user_branch_id() AND user_role_name() = 'manager'))
                     WITH CHECK (is_admin() OR (branch_id = user_branch_id() AND user_role_name() = 'manager'));

-- The balance is maintained by triggers only (they are SECURITY DEFINER and
-- unaffected). This stops any client from editing it by hand.
REVOKE UPDATE (current_balance) ON customers FROM authenticated;

-- ----------------------------------------------------------------------------
-- 4. DATE-RANGE REPORT FUNCTIONS
--    p_from / p_to are inclusive dates. Default SECURITY INVOKER, so the RLS
--    above applies: admin gets every branch, staff only their own.
--    Dates are read in Malawi time (a sale at 11pm must not count as
--    "tomorrow", which is what happens when the server uses UTC).
-- ----------------------------------------------------------------------------

-- 4a. Sales per branch for the period
CREATE OR REPLACE FUNCTION report_sales_summary(
    p_from date, p_to date, p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (branch_id uuid, branch_name text, transaction_count bigint, revenue numeric)
LANGUAGE sql STABLE AS $$
SELECT b.id, b.name, COUNT(s.id), COALESCE(SUM(s.total_amount), 0)
FROM branches b
         LEFT JOIN sales s
                   ON s.branch_id = b.id
                       AND s.sale_date >= (p_from::timestamp AT TIME ZONE 'Africa/Blantyre')
                       AND s.sale_date <  ((p_to + 1)::timestamp AT TIME ZONE 'Africa/Blantyre')
WHERE (p_branch_id IS NULL OR b.id = p_branch_id)
  AND (is_admin() OR b.id = user_branch_id())
GROUP BY b.id, b.name
ORDER BY 4 DESC;
$$;

-- 4b. Sales trend for the chart. p_bucket: 'hour' | 'day' | 'week' | 'month' | 'year'
CREATE OR REPLACE FUNCTION report_sales_trend(
    p_from date, p_to date, p_bucket text DEFAULT 'day', p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (period_start timestamp, transaction_count bigint, revenue numeric)
LANGUAGE sql STABLE AS $$
SELECT date_trunc(p_bucket, s.sale_date AT TIME ZONE 'Africa/Blantyre'),
       COUNT(*), SUM(s.total_amount)
FROM sales s
WHERE s.sale_date >= (p_from::timestamp AT TIME ZONE 'Africa/Blantyre')
  AND s.sale_date <  ((p_to + 1)::timestamp AT TIME ZONE 'Africa/Blantyre')
  AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
GROUP BY 1
ORDER BY 1;
$$;

-- 4c. Profit per branch: revenue, cost, gross, expenses, net, ranked by net profit
CREATE OR REPLACE FUNCTION report_profit_summary(
    p_from date, p_to date, p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (branch_id uuid, branch_name text, revenue numeric, cost_of_goods numeric,
               gross_profit numeric, total_expenses numeric, net_profit numeric)
LANGUAGE sql STABLE AS $$
    WITH sold AS (
        SELECT s.branch_id AS bid,
               SUM(si.subtotal)              AS rev,
               SUM(si.unit_cost * si.quantity) AS cogs,
               SUM(si.profit)                AS gp
        FROM sales s
        JOIN sale_items si ON si.sale_id = s.id
        WHERE s.sale_date >= (p_from::timestamp AT TIME ZONE 'Africa/Blantyre')
          AND s.sale_date <  ((p_to + 1)::timestamp AT TIME ZONE 'Africa/Blantyre')
        GROUP BY s.branch_id
    ),
    spent AS (
        SELECT e.branch_id AS bid, SUM(e.amount) AS total
        FROM expenses e
        WHERE e.expense_date BETWEEN p_from AND p_to
        GROUP BY e.branch_id
    )
SELECT b.id, b.name,
       COALESCE(sold.rev, 0), COALESCE(sold.cogs, 0), COALESCE(sold.gp, 0),
       COALESCE(spent.total, 0),
       COALESCE(sold.gp, 0) - COALESCE(spent.total, 0)
FROM branches b
         LEFT JOIN sold  ON sold.bid  = b.id
         LEFT JOIN spent ON spent.bid = b.id
WHERE (p_branch_id IS NULL OR b.id = p_branch_id)
  AND (is_admin() OR b.id = user_branch_id())
ORDER BY 7 DESC;
$$;

-- 4d. Best sellers. p_rank_by: 'quantity' | 'revenue' | 'profit' | 'frequency'
CREATE OR REPLACE FUNCTION report_best_sellers(
    p_from date, p_to date, p_branch_id uuid DEFAULT NULL,
    p_rank_by text DEFAULT 'quantity', p_limit int DEFAULT 10)
RETURNS TABLE (item_id uuid, item_name text, total_quantity_sold numeric,
               total_revenue numeric, total_profit numeric, times_sold bigint)
LANGUAGE sql STABLE AS $$
SELECT si.item_id, i.name,
       SUM(si.quantity), SUM(si.subtotal), SUM(si.profit),
       COUNT(DISTINCT si.sale_id)
FROM sale_items si
         JOIN sales s ON s.id = si.sale_id
         JOIN items i ON i.id = si.item_id
WHERE s.sale_date >= (p_from::timestamp AT TIME ZONE 'Africa/Blantyre')
  AND s.sale_date <  ((p_to + 1)::timestamp AT TIME ZONE 'Africa/Blantyre')
  AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
GROUP BY si.item_id, i.name
ORDER BY CASE p_rank_by
    WHEN 'revenue'   THEN SUM(si.subtotal)
    WHEN 'profit'    THEN SUM(si.profit)
    WHEN 'frequency' THEN COUNT(DISTINCT si.sale_id)
    ELSE SUM(si.quantity)
END DESC
    LIMIT p_limit;
$$;

-- 4e. Expenses by category (and branch) for the period
CREATE OR REPLACE FUNCTION report_expenses_by_category(
    p_from date, p_to date, p_branch_id uuid DEFAULT NULL)
RETURNS TABLE (branch_id uuid, branch_name text, category text, total_amount numeric)
LANGUAGE sql STABLE AS $$
SELECT e.branch_id, b.name, e.category, SUM(e.amount)
FROM expenses e
         JOIN branches b ON b.id = e.branch_id
WHERE e.expense_date BETWEEN p_from AND p_to
  AND (p_branch_id IS NULL OR e.branch_id = p_branch_id)
GROUP BY e.branch_id, b.name, e.category
ORDER BY 4 DESC;
$$;

-- Signed-in users only
REVOKE ALL ON FUNCTION report_sales_summary(date, date, uuid)                FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION report_sales_trend(date, date, text, uuid)            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION report_profit_summary(date, date, uuid)               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION report_best_sellers(date, date, uuid, text, int)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION report_expenses_by_category(date, date, uuid)         FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION report_sales_summary(date, date, uuid)             TO authenticated;
GRANT EXECUTE ON FUNCTION report_sales_trend(date, date, text, uuid)         TO authenticated;
GRANT EXECUTE ON FUNCTION report_profit_summary(date, date, uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION report_best_sellers(date, date, uuid, text, int)   TO authenticated;
GRANT EXECUTE ON FUNCTION report_expenses_by_category(date, date, uuid)      TO authenticated;

                                                     -- ============================================================================
-- SALES: trigger fix, create_sale(), get_receipt(), tighter RLS
-- Run after all earlier migrations.
-- ============================================================================

-- 1. Trigger fixes -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_apply_credit_sale() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.customer_id IS NOT NULL AND NEW.payment_method = 'credit' THEN
UPDATE customers
SET current_balance = current_balance + (
    COALESCE(NEW.total_amount, 0)
        - CASE WHEN TG_OP = 'UPDATE' THEN COALESCE(OLD.total_amount, 0) ELSE 0 END)
WHERE id = NEW.customer_id;
END IF;
RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_apply_credit_sale ON sales;
CREATE TRIGGER trg_apply_credit_sale
    AFTER INSERT OR UPDATE OF total_amount ON sales          -- amount_paid removed
    FOR EACH ROW EXECUTE FUNCTION fn_apply_credit_sale();

CREATE OR REPLACE FUNCTION fn_apply_payment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.customer_id IS NOT NULL THEN
UPDATE customers SET current_balance = current_balance - NEW.amount
WHERE id = NEW.customer_id;
END IF;

    IF NEW.sale_id IS NOT NULL THEN
UPDATE sales
SET amount_paid = amount_paid + NEW.amount,
    payment_status = CASE
                         WHEN amount_paid + NEW.amount >= total_amount THEN 'paid'::payment_status
                         WHEN amount_paid + NEW.amount > 0            THEN 'partial'::payment_status
                         ELSE 'pending'::payment_status END
WHERE id = NEW.sale_id;
END IF;

    IF NEW.purchase_id IS NOT NULL THEN
UPDATE purchases SET amount_paid = amount_paid + NEW.amount
WHERE id = NEW.purchase_id;
END IF;
RETURN NEW;
END;
$$;

-- 2. Receipt data (used right after a sale, and for reprints) -----------------
CREATE OR REPLACE FUNCTION get_receipt(p_sale_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r jsonb;
BEGIN
SELECT jsonb_build_object(
               'sale_id',         s.id,
               'receipt_number',  s.receipt_number,
               'sale_date',       s.sale_date AT TIME ZONE 'Africa/Blantyre',
               'branch_name',     b.name,
               'branch_location', b.location,
               'branch_phone',    b.phone,
               'cashier_name',    u.full_name,
               'customer_name',   c.name,
               'sale_type',       s.sale_type,
               'payment_method',  s.payment_method,
               'payment_status',  s.payment_status,
               'total_amount',    s.total_amount,
               'amount_paid',     s.amount_paid,
               'balance_due',     s.total_amount - s.amount_paid,
               'items', COALESCE((
                                     SELECT jsonb_agg(jsonb_build_object(
                                                              'name', i.name, 'quantity', si.quantity,
                                                              'unit_price', si.unit_price, 'subtotal', si.subtotal)
                                                          ORDER BY i.name, si.id)
                                     FROM sale_items si JOIN items i ON i.id = si.item_id
                                     WHERE si.sale_id = s.id), '[]'::jsonb)
       ) INTO r
FROM sales s
         JOIN branches b ON b.id = s.branch_id
         LEFT JOIN users u ON u.id = s.cashier_id
         LEFT JOIN customers c ON c.id = s.customer_id
WHERE s.id = p_sale_id
  AND (is_admin() OR s.branch_id = user_branch_id());   -- same rule as RLS

IF r IS NULL THEN RAISE EXCEPTION 'Receipt not found.'; END IF;
RETURN r;
END;
$$;

-- 3. The sale function --------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS receipt_seq;

CREATE OR REPLACE FUNCTION create_sale(
    p_lines          jsonb,                          -- [{"item_id":"...","quantity":2}, ...]
    p_sale_type      sale_type      DEFAULT 'retail',
    p_payment_method payment_method DEFAULT 'cash',
    p_customer_id    uuid           DEFAULT NULL,    -- required when credit
    p_amount_paid    numeric        DEFAULT 0,       -- credit only: paid now
    p_paid_method    payment_method DEFAULT 'cash',  -- how that part-payment was made
    p_branch_id      uuid           DEFAULT NULL     -- admin only
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
v_uid       uuid := auth.uid();
    v_today     date := (now() AT TIME ZONE 'Africa/Blantyre')::date;
    v_role      user_role;
    v_branch    uuid;
    v_prefix    text;
    v_sale_id   uuid;
    v_line      record;
    v_batch     record;
    v_item_name text;
    v_remaining numeric;
    v_take      numeric;
    v_price     numeric;
    v_total     numeric;
BEGIN
    -- who is selling, and where
SELECT role, branch_id INTO v_role, v_branch FROM users WHERE id = v_uid AND is_active;
IF v_role IS NULL THEN RAISE EXCEPTION 'Your account is not active.'; END IF;
    IF v_role = 'admin' THEN
        v_branch := p_branch_id;
        IF v_branch IS NULL THEN RAISE EXCEPTION 'Choose a branch to sell from.'; END IF;
    ELSIF v_role NOT IN ('cashier', 'manager') THEN
        RAISE EXCEPTION 'Your role cannot record sales.';
END IF;
    IF NOT EXISTS (SELECT 1 FROM branches WHERE id = v_branch AND is_active) THEN
        RAISE EXCEPTION 'Branch not found or inactive.';
END IF;

    -- basic validation
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one item to the sale.';
END IF;
    IF p_payment_method = 'credit' AND p_customer_id IS NULL THEN
        RAISE EXCEPTION 'A customer is required for credit sales.';
END IF;
    IF p_customer_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM customers WHERE id = p_customer_id
           AND (branch_id IS NULL OR branch_id = v_branch)) THEN
        RAISE EXCEPTION 'Customer not found at this branch.';
END IF;

    -- receipt number, e.g. MZU-000123
SELECT upper(left(regexp_replace(name, '[^A-Za-z]', '', 'g'), 3))
INTO v_prefix FROM branches WHERE id = v_branch;
INSERT INTO sales (branch_id, customer_id, cashier_id, sale_type, payment_method,
                   payment_status, receipt_number)
VALUES (v_branch, p_customer_id, v_uid, p_sale_type, p_payment_method,
        CASE WHEN p_payment_method = 'credit'
                 THEN 'pending'::payment_status ELSE 'paid'::payment_status END,
        COALESCE(NULLIF(v_prefix, ''), 'RCT') || '-' || lpad(nextval('receipt_seq')::text, 6, '0'))
    RETURNING id INTO v_sale_id;

-- one pass per item, always in item_id order so two sales can't deadlock
FOR v_line IN
SELECT (l->>'item_id')::uuid AS item_id,
       SUM((l->>'quantity')::numeric) AS qty,
       COALESCE(NULLIF(l->>'unit', ''), NULL) AS unit_name
FROM jsonb_array_elements(p_lines) AS l
GROUP BY 1, 3 ORDER BY 1
    LOOP
        IF v_line.qty <= 0 THEN RAISE EXCEPTION 'Quantities must be greater than zero.'; END IF;

SELECT name INTO v_item_name FROM items WHERE id = v_line.item_id AND is_active;
IF v_item_name IS NULL THEN RAISE EXCEPTION 'An item in this sale is missing or discontinued.'; END IF;

        -- Convert to the item's base unit (inventory is always counted in base).
        -- A missing/unknown unit means the quantity is already in base units.
        v_remaining := to_base_qty(v_line.item_id, COALESCE(v_line.unit_name, ''), v_line.qty);

        -- first-expiry-first-out; skip expired batches; lock rows so nobody else can sell them
FOR v_batch IN
SELECT id, buying_price, retail_price, wholesale_price, quantity_available
FROM inventory
WHERE branch_id = v_branch AND item_id = v_line.item_id
  AND quantity_available > 0
  AND (expiry_date IS NULL OR expiry_date >= v_today)
ORDER BY expiry_date ASC NULLS LAST, received_date ASC, created_at ASC
    FOR UPDATE
    LOOP
            EXIT WHEN v_remaining <= 0;
v_take  := LEAST(v_remaining, v_batch.quantity_available);
            v_price := CASE WHEN p_sale_type = 'wholesale'
                            THEN COALESCE(v_batch.wholesale_price, v_batch.retail_price)
                            ELSE v_batch.retail_price END;

INSERT INTO sale_items (sale_id, item_id, inventory_id, quantity,
                        unit_price, unit_cost, subtotal, unit)
VALUES (v_sale_id, v_line.item_id, v_batch.id, v_take,
        v_price, v_batch.buying_price, v_take * v_price, v_line.unit_name);

UPDATE inventory SET quantity_available = quantity_available - v_take
WHERE id = v_batch.id;

INSERT INTO stock_movements (branch_id, item_id, inventory_id, movement_type,
                             quantity, reference_table, reference_id, performed_by)
VALUES (v_branch, v_line.item_id, v_batch.id, 'sale_out',
        v_take, 'sales', v_sale_id, v_uid);

v_remaining := v_remaining - v_take;
END LOOP;

        IF v_remaining > 0 THEN
            RAISE EXCEPTION 'Not enough stock for %: only % available.',
                            v_item_name, v_line.qty - v_remaining;   -- rolls back the whole sale
END IF;
END LOOP;

    -- payment (total_amount was filled in by the sale_items trigger)
SELECT total_amount INTO v_total FROM sales WHERE id = v_sale_id;

IF p_payment_method = 'credit' THEN
        IF COALESCE(p_amount_paid, 0) < 0 OR COALESCE(p_amount_paid, 0) > v_total THEN
            RAISE EXCEPTION 'Amount paid now must be between 0 and the sale total.';
END IF;
        IF COALESCE(p_amount_paid, 0) > 0 THEN
            IF p_paid_method = 'credit' THEN
                RAISE EXCEPTION 'Choose how the part-payment was made (cash, mobile money or card).';
END IF;
INSERT INTO payments (branch_id, customer_id, sale_id, amount, payment_method,
                      recorded_by, notes)
VALUES (v_branch, p_customer_id, v_sale_id, p_amount_paid, p_paid_method,
        v_uid, 'Part-payment at time of sale');
END IF;
ELSE
UPDATE sales SET amount_paid = total_amount WHERE id = v_sale_id;
END IF;

RETURN get_receipt(v_sale_id);
END;
$$;

REVOKE ALL ON FUNCTION get_receipt(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION create_sale(jsonb, sale_type, payment_method, uuid, numeric, payment_method, uuid)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION get_receipt(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION create_sale(jsonb, sale_type, payment_method, uuid, numeric, payment_method, uuid)
    TO authenticated;

-- 4. RLS -----------------------------------------------------------------------
-- Sales can only be created through create_sale(), so remove the direct inserts
-- (otherwise a cashier could insert a sale line with any price and no stock deducted).
DROP POLICY IF EXISTS "Staff record sales at own branch" ON sales;
DROP POLICY IF EXISTS "Insert sale_items via parent sale access" ON sale_items;

-- Inventory: cashiers can view stock but no longer change it.
DROP POLICY IF EXISTS "Admins and staff manage own branch inventory" ON inventory;

CREATE POLICY "Inventory insert: admin, or manager/stock controller at own branch"
    ON inventory FOR INSERT
    WITH CHECK (is_admin() OR (branch_id = user_branch_id()
                               AND user_role_name() IN ('manager', 'stock_controller')));

CREATE POLICY "Inventory update: admin, or manager/stock controller at own branch"
    ON inventory FOR UPDATE
                                                                                                                                USING      (is_admin() OR (branch_id = user_branch_id()
                                                                                                                                AND user_role_name() IN ('manager', 'stock_controller')))
                     WITH CHECK (is_admin() OR (branch_id = user_branch_id()
                                                                                                                                AND user_role_name() IN ('manager', 'stock_controller')));

CREATE POLICY "Admins delete inventory" ON inventory FOR DELETE USING (is_admin());


                                                                -- ============================================================================
-- TEMPORARY STOCK ACCESS FOR CASHIERS: request -> admin approves -> admin revokes
-- ============================================================================

CREATE TYPE stock_access_status AS ENUM ('pending', 'approved', 'denied', 'revoked', 'expired');

CREATE TABLE stock_access_grants (
                                     id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                                     user_id       uuid NOT NULL REFERENCES users(id),
                                     branch_id     uuid NOT NULL REFERENCES branches(id),
                                     reason        text,
                                     status        stock_access_status NOT NULL DEFAULT 'pending',
                                     requested_at  timestamptz NOT NULL DEFAULT now(),
                                     decided_by    uuid REFERENCES users(id),
                                     decided_at    timestamptz,
                                     expires_at    timestamptz,                -- NULL = until the admin removes it
                                     revoked_by    uuid REFERENCES users(id),
                                     revoked_at    timestamptz
);

-- One open request or grant per person
CREATE UNIQUE INDEX one_open_stock_access_per_user
    ON stock_access_grants(user_id) WHERE status IN ('pending', 'approved');

-- Clients can only READ this table; every change goes through the functions below
ALTER TABLE stock_access_grants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "View stock access: admin all, user own"
    ON stock_access_grants FOR SELECT
                                          USING (is_admin() OR user_id = auth.uid());

-- The one helper every stock rule uses
CREATE OR REPLACE FUNCTION has_stock_access() RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
SELECT COALESCE((
                    SELECT u.is_active AND (
                        u.role IN ('admin', 'manager', 'stock_controller')
                            OR EXISTS (SELECT 1 FROM stock_access_grants g
                                       WHERE g.user_id = u.id AND g.status = 'approved'
                                         AND (g.expires_at IS NULL OR g.expires_at > now())))
                    FROM users u WHERE u.id = auth.uid()), false);
$$;

ALTER TABLE users DROP COLUMN IF EXISTS can_manage_stock;   -- from the earlier idea

DROP POLICY IF EXISTS "Record movements: admin all, staff own branch" ON stock_movements;
DROP POLICY IF EXISTS "Record movements: admin or stock access at own branch" ON stock_movements;
CREATE POLICY "Record movements: admin or stock access at own branch"
    ON stock_movements FOR INSERT
    WITH CHECK (is_admin() OR (branch_id = user_branch_id() AND has_stock_access()));

-- Inventory, purchases and purchase lines now follow the helper
DROP POLICY IF EXISTS "Inventory insert: admin, or manager/stock controller at own branch" ON inventory;
DROP POLICY IF EXISTS "Inventory update: admin, or manager/stock controller at own branch" ON inventory;
DROP POLICY IF EXISTS "Inventory insert: stock access at own branch" ON inventory;
DROP POLICY IF EXISTS "Inventory update: stock access at own branch" ON inventory;

CREATE POLICY "Inventory insert: stock access at own branch" ON inventory FOR INSERT
    WITH CHECK (is_admin() OR (branch_id = user_branch_id() AND has_stock_access()));
CREATE POLICY "Inventory update: stock access at own branch" ON inventory FOR UPDATE
                                                                                                             USING      (is_admin() OR (branch_id = user_branch_id() AND has_stock_access()))
                                                                              WITH CHECK (is_admin() OR (branch_id = user_branch_id() AND has_stock_access()));

DROP POLICY IF EXISTS "Create purchases: admin, or manager/stock controller at own branch" ON purchases;
DROP POLICY IF EXISTS "Create purchases: stock access at own branch" ON purchases;
CREATE POLICY "Create purchases: stock access at own branch" ON purchases FOR INSERT
    WITH CHECK (is_admin() OR (branch_id = user_branch_id() AND has_stock_access()));

DROP POLICY IF EXISTS "Insert purchase_items via parent purchase" ON purchase_items;
CREATE POLICY "Insert purchase_items via parent purchase" ON purchase_items FOR INSERT
    WITH CHECK (EXISTS (
        SELECT 1 FROM purchases p
        WHERE p.id = purchase_items.purchase_id
          AND (is_admin() OR (p.branch_id = user_branch_id() AND has_stock_access()))));

-- 1. Cashier asks
CREATE OR REPLACE FUNCTION request_stock_access(p_reason text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_role user_role; v_branch uuid; v_id uuid;
BEGIN
SELECT role, branch_id INTO v_role, v_branch FROM users WHERE id = v_uid AND is_active;
IF v_role IS NULL THEN RAISE EXCEPTION 'Your account is not active.'; END IF;
    IF v_role <> 'cashier' THEN
        RAISE EXCEPTION 'Only cashiers need to request stock access.';
END IF;

UPDATE stock_access_grants SET status = 'expired'          -- tidy up timed-out grants
WHERE user_id = v_uid AND status = 'approved'
  AND expires_at IS NOT NULL AND expires_at <= now();

IF EXISTS (SELECT 1 FROM stock_access_grants WHERE user_id = v_uid AND status = 'pending') THEN
        RAISE EXCEPTION 'You already have a request waiting for the admin.';
END IF;
    IF EXISTS (SELECT 1 FROM stock_access_grants WHERE user_id = v_uid AND status = 'approved') THEN
        RAISE EXCEPTION 'You already have stock access.';
END IF;

INSERT INTO stock_access_grants (user_id, branch_id, reason)
VALUES (v_uid, v_branch, NULLIF(trim(p_reason), ''))
    RETURNING id INTO v_id;
RETURN v_id;
END;
$$;

-- 2. Admin approves (optionally with a time limit in hours) or denies
CREATE OR REPLACE FUNCTION decide_stock_access(
    p_request_id uuid, p_approve boolean, p_hours int DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_admin() THEN RAISE EXCEPTION 'Only admins can approve stock access.'; END IF;
    IF p_hours IS NOT NULL AND p_hours <= 0 THEN
        RAISE EXCEPTION 'The time limit must be above zero hours.';
END IF;

UPDATE stock_access_grants
SET status = CASE WHEN p_approve THEN 'approved'::stock_access_status
                  ELSE 'denied'::stock_access_status END,
    decided_by = auth.uid(),
    decided_at = now(),
    expires_at = CASE WHEN p_approve AND p_hours IS NOT NULL
                          THEN now() + make_interval(hours => p_hours) END
WHERE id = p_request_id AND status = 'pending';
IF NOT FOUND THEN RAISE EXCEPTION 'This request is no longer waiting.'; END IF;
END;
$$;

-- 3. Admin removes access (the cashier can also hand it back with "I'm done")
CREATE OR REPLACE FUNCTION revoke_stock_access(p_request_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
UPDATE stock_access_grants
SET status = 'revoked', revoked_by = auth.uid(), revoked_at = now()
WHERE id = p_request_id AND status = 'approved'
  AND (is_admin() OR user_id = auth.uid());
IF NOT FOUND THEN RAISE EXCEPTION 'There is no active stock access to end.'; END IF;
END;
$$;

-- Receive a complete delivery atomically. The cashier may only receive into
-- their own branch while access is active; managers, stock controllers and
-- admins retain their existing stock-entry capability.
CREATE OR REPLACE FUNCTION receive_stock_delivery(
    p_branch_id uuid,
    p_supplier_id uuid DEFAULT NULL,
    p_invoice_number text DEFAULT NULL,
    p_purchase_date date DEFAULT current_date,
    p_lines jsonb DEFAULT '[]'::jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_role user_role;
    v_user_branch uuid;
    v_purchase_id uuid;
    v_line jsonb;
    v_item_id uuid;
    v_inventory_id uuid;
    v_qty numeric;
    v_buying numeric;
    v_retail numeric;
    v_wholesale numeric;
    v_expiry date;
    v_batch text;
BEGIN
    SELECT role, branch_id INTO v_role, v_user_branch
    FROM users WHERE id = v_uid AND is_active;
    IF v_role IS NULL THEN RAISE EXCEPTION 'Your account is not active.'; END IF;
    IF p_branch_id IS NULL THEN RAISE EXCEPTION 'Choose a branch.'; END IF;
    IF v_role = 'cashier' THEN
        IF v_user_branch IS DISTINCT FROM p_branch_id OR NOT has_stock_access() THEN
            RAISE EXCEPTION 'Active stock access is required to receive stock at your branch.';
        END IF;
    ELSIF v_role NOT IN ('admin', 'manager', 'stock_controller') THEN
        RAISE EXCEPTION 'Your role cannot receive stock.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM branches WHERE id = p_branch_id AND is_active) THEN
        RAISE EXCEPTION 'Branch not found or inactive.';
    END IF;
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one delivery line.';
    END IF;
    IF p_supplier_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND is_active
    ) THEN
        RAISE EXCEPTION 'Supplier not found or inactive.';
    END IF;

    INSERT INTO purchases (
        branch_id, supplier_id, invoice_number, payment_status,
        purchase_date, created_by
    ) VALUES (
        p_branch_id, p_supplier_id, NULLIF(trim(p_invoice_number), ''),
        CASE WHEN p_supplier_id IS NULL THEN 'paid'::payment_status
             ELSE 'pending'::payment_status END,
        COALESCE(p_purchase_date, current_date), v_uid
    ) RETURNING id INTO v_purchase_id;

    FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
    LOOP
        v_item_id := (v_line->>'item_id')::uuid;
        v_qty := (v_line->>'quantity')::numeric;
        v_buying := (v_line->>'buying_price')::numeric;
        v_retail := (v_line->>'retail_price')::numeric;
        v_wholesale := NULLIF(v_line->>'wholesale_price', '')::numeric;
        v_expiry := NULLIF(v_line->>'expiry_date', '')::date;
        v_batch := NULLIF(trim(v_line->>'batch_number'), '');

        IF v_qty IS NULL OR v_qty <= 0 OR v_buying IS NULL OR v_buying < 0
           OR v_retail IS NULL OR v_retail < 0 THEN
            RAISE EXCEPTION 'Each delivery line needs valid quantity and prices.';
        END IF;
        IF v_wholesale IS NOT NULL AND v_wholesale < 0 THEN
            RAISE EXCEPTION 'Wholesale prices cannot be negative.';
        END IF;
        IF v_expiry IS NOT NULL AND v_expiry < current_date THEN
            RAISE EXCEPTION 'Expiry dates cannot be in the past.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM items WHERE id = v_item_id AND is_active) THEN
            RAISE EXCEPTION 'An item is missing or discontinued.';
        END IF;

        -- A bigger unit ("2 bottles") converts to base units ("200 ml").
        -- Prices are per base unit and must NOT be scaled.
        v_qty := to_base_qty(v_item_id, COALESCE(NULLIF(trim(v_line->>'unit'), ''), ''), v_qty);

        INSERT INTO inventory (
            item_id, branch_id, batch_number, buying_price, retail_price,
            wholesale_price, quantity_received, quantity_available,
            expiry_date, received_date, created_by
        ) VALUES (
            v_item_id, p_branch_id, v_batch, v_buying, v_retail,
            v_wholesale, v_qty, v_qty, v_expiry,
            COALESCE(p_purchase_date, current_date), v_uid
        ) RETURNING id INTO v_inventory_id;

        INSERT INTO purchase_items (
            purchase_id, item_id, inventory_id, quantity, unit_cost, subtotal
        ) VALUES (
            v_purchase_id, v_item_id, v_inventory_id, v_qty, v_buying, v_qty * v_buying
        );

        INSERT INTO stock_movements (
            branch_id, item_id, inventory_id, movement_type, quantity,
            reference_table, reference_id, performed_by, notes
        ) VALUES (
            p_branch_id, v_item_id, v_inventory_id, 'purchase_in', v_qty,
            'purchases', v_purchase_id, v_uid, 'Received delivery'
        );
    END LOOP;
    RETURN v_purchase_id;
END;
$$;

-- 4. Readable list for the admin screen and the cashier's own status.
--    Also returns who approved / ended each access, so History can name them.
CREATE OR REPLACE VIEW v_stock_access_requests WITH (security_invoker = true) AS
SELECT g.id, g.user_id, u.full_name, g.branch_id, b.name AS branch_name,
       g.reason, g.requested_at, g.decided_at, g.expires_at, g.revoked_at,
       d.full_name AS decided_by_name, r.full_name AS revoked_by_name,
       g.revoked_by AS revoked_by_id,
       CASE WHEN g.status = 'approved' AND g.expires_at IS NOT NULL AND g.expires_at <= now()
                THEN 'expired' ELSE g.status::text END AS effective_status
FROM stock_access_grants g
         JOIN users u ON u.id = g.user_id
         JOIN branches b ON b.id = g.branch_id
         LEFT JOIN users d ON d.id = g.decided_by
         LEFT JOIN users r ON r.id = g.revoked_by
ORDER BY g.requested_at DESC;

REVOKE ALL ON FUNCTION request_stock_access(text)             FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION decide_stock_access(uuid, boolean, int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION revoke_stock_access(uuid)              FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION request_stock_access(text)             TO authenticated;
GRANT EXECUTE ON FUNCTION decide_stock_access(uuid, boolean, int) TO authenticated;
GRANT EXECUTE ON FUNCTION revoke_stock_access(uuid)              TO authenticated;
REVOKE ALL ON FUNCTION receive_stock_delivery(uuid, uuid, text, date, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION receive_stock_delivery(uuid, uuid, text, date, jsonb) TO authenticated;



-- ----------------------------------------------------------------------------
-- SELF-SERVICE PROFILE: cashiers can fix their own name/phone only.
-- Staff cannot UPDATE users directly (admin-only policies), so this
-- SECURITY DEFINER function updates exactly two columns for auth.uid().
-- Role, branch and active status can never change through it.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_own_profile(p_full_name text, p_phone text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;
  IF trim(COALESCE(p_full_name, '')) = '' THEN
    RAISE EXCEPTION 'Full name is required.';
  END IF;
  UPDATE users
  SET full_name = trim(p_full_name),
      phone = NULLIF(trim(COALESCE(p_phone, '')), '')
  WHERE id = v_uid AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Your account was not found.'; END IF;
END;
$$;

REVOKE ALL ON FUNCTION update_own_profile(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_own_profile(text, text) TO authenticated;

-- ----------------------------------------------------------------------------
-- MIGRATION: Malawi mobile money split (run once on existing databases).
-- Fresh installs already get the new values from the CREATE TYPE above.
-- 'mobile_money' is kept so existing rows stay valid.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'payment_method' AND e.enumlabel = 'airtel_money'
  ) THEN
    ALTER TYPE payment_method ADD VALUE 'airtel_money';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'payment_method' AND e.enumlabel = 'tnm_mpamba'
  ) THEN
    ALTER TYPE payment_method ADD VALUE 'tnm_mpamba';
  END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- MIGRATION: let branch staff (cashier, stock controller, manager) record
-- their own branch's expenses (run once on existing databases). Fresh
-- installs are covered by the policies above plus this one.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'expenses'
      AND policyname = 'Staff record own branch expenses'
  ) THEN
    CREATE POLICY "Staff record own branch expenses"
      ON expenses FOR INSERT
      WITH CHECK (branch_id = user_branch_id());
  END IF;
END
$$;



-- ============================================================================
-- BRANCH BUSINESS TYPES: each branch (shop) only sees the catalogue(s) of the
-- business type(s) it runs. A branch can opt in to more than one type.
-- Run once, after all earlier migrations (reuses is_admin(), user_branch_id()).
--
-- Model:
--   business_types         e.g. Pharmacy, Cosmetics (admin can type new ones)
--   items.business_type_id each catalogue item belongs to exactly one type
--   branch_business_types  which types each branch runs (1 or more)
-- ============================================================================

-- 1. Business types ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS business_types (
                                              id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
    );
-- case-insensitive unique, so "cosmetics" and "Cosmetics" can't both exist
CREATE UNIQUE INDEX IF NOT EXISTS uq_business_types_name ON business_types (lower(trim(name)));

INSERT INTO business_types (name) VALUES ('Pharmacy'), ('Cosmetics')
    ON CONFLICT DO NOTHING;

-- 2. Items belong to a business type -----------------------------------------
ALTER TABLE items ADD COLUMN IF NOT EXISTS business_type_id uuid REFERENCES business_types(id);

-- everything that exists today is a drug-store item
UPDATE items
SET business_type_id = (SELECT id FROM business_types WHERE lower(name) = 'pharmacy')
WHERE business_type_id IS NULL;

ALTER TABLE items ALTER COLUMN business_type_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS idx_items_business_type ON items(business_type_id);

-- 3. Which types each branch runs ---------------------------------------------
CREATE TABLE IF NOT EXISTS branch_business_types (
                                                     branch_id         uuid NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
    business_type_id  uuid NOT NULL REFERENCES business_types(id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (branch_id, business_type_id)
    );
CREATE INDEX IF NOT EXISTS idx_bbt_type ON branch_business_types(business_type_id);

-- existing branches keep working: they all become Pharmacy branches
INSERT INTO branch_business_types (branch_id, business_type_id)
SELECT b.id, (SELECT id FROM business_types WHERE lower(name) = 'pharmacy')
FROM branches b
    ON CONFLICT DO NOTHING;

-- 4. Helper (SECURITY DEFINER avoids RLS recursion) ----------------------------
CREATE OR REPLACE FUNCTION branch_runs_business_type(p_branch uuid, p_type uuid)
RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
SELECT EXISTS (SELECT 1 FROM branch_business_types
               WHERE branch_id = p_branch AND business_type_id = p_type);
$$;

-- 5. RLS -----------------------------------------------------------------------
ALTER TABLE business_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated users view business types"
    ON business_types FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "Admins manage business types"
    ON business_types FOR ALL USING (is_admin()) WITH CHECK (is_admin());

ALTER TABLE branch_business_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "View branch business types: admin all, staff own branch"
    ON branch_business_types FOR SELECT
                                            USING (is_admin() OR branch_id = user_branch_id());
CREATE POLICY "Admins manage branch business types"
    ON branch_business_types FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- Catalogue visibility: admins see every item (the app filters by the branch
-- being viewed); staff only see items of the types their branch runs.
-- This also filters every security_invoker view built on items.
DROP POLICY IF EXISTS "Authenticated users can view items" ON items;
CREATE POLICY "View items: admin all, staff by branch business type"
    ON items FOR SELECT
                                        USING (is_admin() OR branch_runs_business_type(user_branch_id(), business_type_id));

-- 6. Stop stock of the wrong type entering a branch ----------------------------
-- Covers receive_stock_delivery() and any direct inventory insert.
CREATE OR REPLACE FUNCTION fn_check_inventory_business_type() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_type uuid;
BEGIN
SELECT business_type_id INTO v_type FROM items WHERE id = NEW.item_id;
IF NOT branch_runs_business_type(NEW.branch_id, v_type) THEN
        RAISE EXCEPTION 'This branch does not run the business type of this item. Enable it in the branch settings first.';
END IF;
RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_inventory_business_type ON inventory;
CREATE TRIGGER trg_check_inventory_business_type
    BEFORE INSERT ON inventory
    FOR EACH ROW EXECUTE FUNCTION fn_check_inventory_business_type();

-- 7. Admin sets a branch's business types in one call --------------------------
-- p_type_names are typed names; unknown ones are created on the fly, so the
-- admin can type "Electronics" without a separate "add type" screen.
-- A type can't be removed from a branch while that branch still holds stock of it.
CREATE OR REPLACE FUNCTION admin_set_branch_business_types(
    p_branch_id uuid, p_type_names text[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
v_name   text;
    v_id     uuid;
    v_ids    uuid[] := '{}';
    v_blocked text;
BEGIN
    IF NOT is_admin() THEN RAISE EXCEPTION 'Only admins can change a branch''s business type.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM branches WHERE id = p_branch_id) THEN
        RAISE EXCEPTION 'Branch not found.';
END IF;
    IF p_type_names IS NULL OR array_length(p_type_names, 1) IS NULL THEN
        RAISE EXCEPTION 'Choose at least one business type.';
END IF;

    FOREACH v_name IN ARRAY p_type_names LOOP
        v_name := trim(v_name);
CONTINUE WHEN v_name = '';
SELECT id INTO v_id FROM business_types WHERE lower(trim(name)) = lower(v_name);
IF v_id IS NULL THEN
            INSERT INTO business_types (name) VALUES (v_name) RETURNING id INTO v_id;
END IF;
        v_ids := v_ids || v_id;
END LOOP;

    IF array_length(v_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'Choose at least one business type.';
END IF;

    -- refuse to drop a type that still has stock on the shelf
SELECT string_agg(DISTINCT bt.name, ', ') INTO v_blocked
FROM branch_business_types bbt
         JOIN business_types bt ON bt.id = bbt.business_type_id
WHERE bbt.branch_id = p_branch_id
  AND bbt.business_type_id <> ALL (v_ids)
  AND EXISTS (SELECT 1 FROM inventory inv
                                JOIN items i ON i.id = inv.item_id
              WHERE inv.branch_id = p_branch_id
                AND i.business_type_id = bbt.business_type_id
                AND inv.quantity_available > 0);
IF v_blocked IS NOT NULL THEN
        RAISE EXCEPTION 'Can''t remove % from this branch: it still has stock of that type. Sell or adjust the stock first.', v_blocked;
END IF;

DELETE FROM branch_business_types
WHERE branch_id = p_branch_id AND business_type_id <> ALL (v_ids);

INSERT INTO branch_business_types (branch_id, business_type_id)
SELECT p_branch_id, unnest(v_ids)
    ON CONFLICT DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION admin_set_branch_business_types(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_set_branch_business_types(uuid, text[]) TO authenticated;
REVOKE ALL ON FUNCTION branch_runs_business_type(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION branch_runs_business_type(uuid, uuid) TO authenticated;

-- 8. Readable view for the branch screen ---------------------------------------
CREATE OR REPLACE VIEW v_branch_business_types WITH (security_invoker = true) AS
SELECT b.id AS branch_id, b.name AS branch_name,
       COALESCE(array_agg(bt.name ORDER BY bt.name) FILTER (WHERE bt.id IS NOT NULL), '{}') AS business_types
FROM branches b
         LEFT JOIN branch_business_types bbt ON bbt.branch_id = b.id
         LEFT JOIN business_types bt ON bt.id = bbt.business_type_id
GROUP BY b.id, b.name;

-- ============================================================================
-- CATALOG ACCESS FOR EMPLOYEES
-- Employees (cashiers) can request access to add new products to the catalog.
-- Access is granted by an admin with an optional duration, just like stock access.
-- When adding a product, it must belong to one of the business types their branch runs.
-- The catalog item is then visible to all branches running that business type.
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'catalog_access_status') THEN
        CREATE TYPE catalog_access_status AS ENUM ('pending', 'approved', 'denied', 'revoked', 'expired');
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS catalog_access_grants (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES users(id),
    branch_id     uuid NOT NULL REFERENCES branches(id),
    reason        text,
    status        catalog_access_status NOT NULL DEFAULT 'pending',
    requested_at  timestamptz NOT NULL DEFAULT now(),
    decided_by    uuid REFERENCES users(id),
    decided_at    timestamptz,
    expires_at    timestamptz,                -- NULL = until the admin removes it
    revoked_by    uuid REFERENCES users(id),
    revoked_at    timestamptz
);

-- One open request or grant per person
CREATE UNIQUE INDEX IF NOT EXISTS one_open_catalog_access_per_user
    ON catalog_access_grants(user_id) WHERE status IN ('pending', 'approved');

ALTER TABLE catalog_access_grants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "View catalog access: admin all, user own" ON catalog_access_grants;
CREATE POLICY "View catalog access: admin all, user own"
    ON catalog_access_grants FOR SELECT
    USING (is_admin() OR user_id = auth.uid());

-- Helper: has_catalog_access()
CREATE OR REPLACE FUNCTION has_catalog_access() RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
SELECT COALESCE((
    SELECT u.is_active AND (
        u.role IN ('admin', 'manager')
        OR EXISTS (
            SELECT 1 FROM catalog_access_grants g
            WHERE g.user_id = u.id AND g.status = 'approved'
              AND (g.expires_at IS NULL OR g.expires_at > now())
        )
    )
    FROM users u WHERE u.id = auth.uid()
), false);
$$;

-- 1. Employee asks for catalog access
CREATE OR REPLACE FUNCTION request_catalog_access(p_reason text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_role user_role; v_branch uuid; v_id uuid;
BEGIN
    SELECT role, branch_id INTO v_role, v_branch FROM users WHERE id = v_uid AND is_active;
    IF v_role IS NULL THEN RAISE EXCEPTION 'Your account is not active.'; END IF;
    IF v_role = 'admin' THEN
        RAISE EXCEPTION 'Admins already have full catalog access.';
    END IF;

    UPDATE catalog_access_grants SET status = 'expired'
    WHERE user_id = v_uid AND status = 'approved'
      AND expires_at IS NOT NULL AND expires_at <= now();

    IF EXISTS (SELECT 1 FROM catalog_access_grants WHERE user_id = v_uid AND status = 'pending') THEN
        RAISE EXCEPTION 'You already have a catalog request waiting for the admin.';
    END IF;
    IF EXISTS (SELECT 1 FROM catalog_access_grants WHERE user_id = v_uid AND status = 'approved') THEN
        RAISE EXCEPTION 'You already have catalog access.';
    END IF;

    INSERT INTO catalog_access_grants (user_id, branch_id, reason)
    VALUES (v_uid, v_branch, NULLIF(trim(p_reason), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- 2. Admin decides (approves with optional hours, or denies)
CREATE OR REPLACE FUNCTION decide_catalog_access(
    p_request_id uuid, p_approve boolean, p_hours int DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_admin() THEN RAISE EXCEPTION 'Only admins can approve catalog access.'; END IF;
    IF p_hours IS NOT NULL AND p_hours <= 0 THEN
        RAISE EXCEPTION 'The time limit must be above zero hours.';
    END IF;

    UPDATE catalog_access_grants
    SET status = CASE WHEN p_approve THEN 'approved'::catalog_access_status
                      ELSE 'denied'::catalog_access_status END,
        decided_by = auth.uid(),
        decided_at = now(),
        expires_at = CASE WHEN p_approve AND p_hours IS NOT NULL
                          THEN now() + make_interval(hours => p_hours) END
    WHERE id = p_request_id AND status = 'pending';
    IF NOT FOUND THEN RAISE EXCEPTION 'This request is no longer waiting.'; END IF;
END;
$$;

-- 3. Admin revokes or employee ends access
CREATE OR REPLACE FUNCTION revoke_catalog_access(p_request_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    UPDATE catalog_access_grants
    SET status = 'revoked', revoked_by = auth.uid(), revoked_at = now()
    WHERE id = p_request_id AND status = 'approved'
      AND (is_admin() OR user_id = auth.uid());
    IF NOT FOUND THEN RAISE EXCEPTION 'There is no active catalog access to end.'; END IF;
END;
$$;

-- 4. Add catalog item function
CREATE OR REPLACE FUNCTION add_catalog_item(
    p_name                  text,
    p_business_type_id      uuid,
    p_category              text DEFAULT NULL,
    p_unit                  text DEFAULT 'unit',
    p_reorder_level         numeric DEFAULT 10,
    p_requires_prescription boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_role user_role;
    v_branch uuid;
    v_item_id uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'Not signed in.'; END IF;
    SELECT role, branch_id INTO v_role, v_branch FROM users WHERE id = v_uid AND is_active;
    IF v_role IS NULL THEN RAISE EXCEPTION 'User account is not active.'; END IF;

    IF v_role <> 'admin' THEN
        IF NOT has_catalog_access() THEN
            RAISE EXCEPTION 'Active catalog access is required to add new items.';
        END IF;
        IF NOT branch_runs_business_type(v_branch, p_business_type_id) THEN
            RAISE EXCEPTION 'Your branch does not run this business type. You can only add items for business types your branch operates.';
        END IF;
    END IF;

    IF trim(COALESCE(p_name, '')) = '' THEN
        RAISE EXCEPTION 'Item name is required.';
    END IF;
    IF p_business_type_id IS NULL THEN
        RAISE EXCEPTION 'Business type is required.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM business_types WHERE id = p_business_type_id AND is_active) THEN
        RAISE EXCEPTION 'Business type not found or inactive.';
    END IF;

    INSERT INTO items (
        name,
        business_type_id,
        category,
        unit,
        reorder_level,
        requires_prescription
    ) VALUES (
        trim(p_name),
        p_business_type_id,
        NULLIF(trim(p_category), ''),
        COALESCE(NULLIF(trim(p_unit), ''), 'unit'),
        COALESCE(p_reorder_level, 10),
        COALESCE(p_requires_prescription, false)
    ) RETURNING id INTO v_item_id;

    RETURN v_item_id;
END;
$$;

-- 5. Readable view for admin and cashier status
CREATE OR REPLACE VIEW v_catalog_access_requests WITH (security_invoker = true) AS
SELECT g.id, g.user_id, u.full_name, g.branch_id, b.name AS branch_name,
       g.reason, g.requested_at, g.decided_at, g.expires_at, g.revoked_at,
       d.full_name AS decided_by_name, r.full_name AS revoked_by_name,
       g.revoked_by AS revoked_by_id,
       CASE WHEN g.status = 'approved' AND g.expires_at IS NOT NULL AND g.expires_at <= now()
            THEN 'expired' ELSE g.status::text END AS effective_status
FROM catalog_access_grants g
JOIN users u ON u.id = g.user_id
JOIN branches b ON b.id = g.branch_id
LEFT JOIN users d ON d.id = g.decided_by
LEFT JOIN users r ON r.id = g.revoked_by
ORDER BY g.requested_at DESC;

-- Permissions
REVOKE ALL ON FUNCTION request_catalog_access(text)             FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION decide_catalog_access(uuid, boolean, int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION revoke_catalog_access(uuid)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION has_catalog_access()                     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION add_catalog_item(text, uuid, text, text, numeric, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION request_catalog_access(text)             TO authenticated;
GRANT EXECUTE ON FUNCTION decide_catalog_access(uuid, boolean, int) TO authenticated;
GRANT EXECUTE ON FUNCTION revoke_catalog_access(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION has_catalog_access()                     TO authenticated;
GRANT EXECUTE ON FUNCTION add_catalog_item(text, uuid, text, text, numeric, boolean) TO authenticated;

select proname, pg_get_function_arguments(oid)
from pg_proc
where proname in ('request_catalog_access', 'has_catalog_access',
                  'decide_catalog_access', 'revoke_catalog_access',
                  'add_catalog_item');



-- ============================================================================
-- CATALOG ACCESS FOR EMPLOYEES
-- Run AFTER branch_business_types.sql (needs branch_runs_business_type(),
-- business_types, items.business_type_id) and the stock access migration.
--
-- Employees (cashiers) request access to add new products to the catalog.
-- An admin approves (optionally time-limited) or denies, and can revoke.
-- A product must belong to a business type the employee's branch runs, and
-- is then visible to every branch running that type.
-- Safe to re-run.
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'catalog_access_status') THEN
CREATE TYPE catalog_access_status AS ENUM ('pending', 'approved', 'denied', 'revoked', 'expired');
END IF;
END
$$;

CREATE TABLE IF NOT EXISTS catalog_access_grants (
                                                     id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES users(id),
    branch_id     uuid NOT NULL REFERENCES branches(id),
    reason        text,
    status        catalog_access_status NOT NULL DEFAULT 'pending',
    requested_at  timestamptz NOT NULL DEFAULT now(),
    decided_by    uuid REFERENCES users(id),
    decided_at    timestamptz,
    expires_at    timestamptz,                -- NULL = until the admin removes it
    revoked_by    uuid REFERENCES users(id),
    revoked_at    timestamptz
    );

-- One open request or grant per person
CREATE UNIQUE INDEX IF NOT EXISTS one_open_catalog_access_per_user
    ON catalog_access_grants(user_id) WHERE status IN ('pending', 'approved');

ALTER TABLE catalog_access_grants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "View catalog access: admin all, user own" ON catalog_access_grants;
CREATE POLICY "View catalog access: admin all, user own"
    ON catalog_access_grants FOR SELECT
                                                 USING (is_admin() OR user_id = auth.uid());

-- Helper: has_catalog_access()
CREATE OR REPLACE FUNCTION has_catalog_access() RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
SELECT COALESCE((
                    SELECT u.is_active AND (
                        u.role IN ('admin', 'manager')
                            OR EXISTS (
                            SELECT 1 FROM catalog_access_grants g
                            WHERE g.user_id = u.id AND g.status = 'approved'
                              AND (g.expires_at IS NULL OR g.expires_at > now())
                        )
                        )
                    FROM users u WHERE u.id = auth.uid()
                ), false);
$$;

-- 1. Employee asks for catalog access
CREATE OR REPLACE FUNCTION request_catalog_access(p_reason text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := auth.uid(); v_role user_role; v_branch uuid; v_id uuid;
BEGIN
SELECT role, branch_id INTO v_role, v_branch FROM users WHERE id = v_uid AND is_active;
IF v_role IS NULL THEN RAISE EXCEPTION 'Your account is not active.'; END IF;
    IF v_role = 'admin' THEN
        RAISE EXCEPTION 'Admins already have full catalog access.';
END IF;

UPDATE catalog_access_grants SET status = 'expired'
WHERE user_id = v_uid AND status = 'approved'
  AND expires_at IS NOT NULL AND expires_at <= now();

IF EXISTS (SELECT 1 FROM catalog_access_grants WHERE user_id = v_uid AND status = 'pending') THEN
        RAISE EXCEPTION 'You already have a catalog request waiting for the admin.';
END IF;
    IF EXISTS (SELECT 1 FROM catalog_access_grants WHERE user_id = v_uid AND status = 'approved') THEN
        RAISE EXCEPTION 'You already have catalog access.';
END IF;

INSERT INTO catalog_access_grants (user_id, branch_id, reason)
VALUES (v_uid, v_branch, NULLIF(trim(p_reason), ''))
    RETURNING id INTO v_id;
RETURN v_id;
END;
$$;

-- 2. Admin decides (approves with optional hours, or denies)
CREATE OR REPLACE FUNCTION decide_catalog_access(
    p_request_id uuid, p_approve boolean, p_hours int DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NOT is_admin() THEN RAISE EXCEPTION 'Only admins can approve catalog access.'; END IF;
    IF p_hours IS NOT NULL AND p_hours <= 0 THEN
        RAISE EXCEPTION 'The time limit must be above zero hours.';
END IF;

UPDATE catalog_access_grants
SET status = CASE WHEN p_approve THEN 'approved'::catalog_access_status
                  ELSE 'denied'::catalog_access_status END,
    decided_by = auth.uid(),
    decided_at = now(),
    expires_at = CASE WHEN p_approve AND p_hours IS NOT NULL
                          THEN now() + make_interval(hours => p_hours) END
WHERE id = p_request_id AND status = 'pending';
IF NOT FOUND THEN RAISE EXCEPTION 'This request is no longer waiting.'; END IF;
END;
$$;

-- 3. Admin revokes, or the employee ends their own access
CREATE OR REPLACE FUNCTION revoke_catalog_access(p_request_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
UPDATE catalog_access_grants
SET status = 'revoked', revoked_by = auth.uid(), revoked_at = now()
WHERE id = p_request_id AND status = 'approved'
  AND (is_admin() OR user_id = auth.uid());
IF NOT FOUND THEN RAISE EXCEPTION 'There is no active catalog access to end.'; END IF;
END;
$$;

-- 4. Add a catalog item
CREATE OR REPLACE FUNCTION add_catalog_item(
    p_name                  text,
    p_business_type_id      uuid,
    p_category              text DEFAULT NULL,
    p_unit                  text DEFAULT 'unit',
    p_reorder_level         numeric DEFAULT 10,
    p_requires_prescription boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
v_uid uuid := auth.uid();
    v_role user_role;
    v_branch uuid;
    v_item_id uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'Not signed in.'; END IF;
SELECT role, branch_id INTO v_role, v_branch FROM users WHERE id = v_uid AND is_active;
IF v_role IS NULL THEN RAISE EXCEPTION 'User account is not active.'; END IF;

    IF v_role <> 'admin' THEN
        IF NOT has_catalog_access() THEN
            RAISE EXCEPTION 'Active catalog access is required to add new items.';
END IF;
        IF NOT branch_runs_business_type(v_branch, p_business_type_id) THEN
            RAISE EXCEPTION 'Your branch does not run this business type. You can only add items for business types your branch operates.';
END IF;
END IF;

    IF trim(COALESCE(p_name, '')) = '' THEN
        RAISE EXCEPTION 'Item name is required.';
END IF;
    IF p_business_type_id IS NULL THEN
        RAISE EXCEPTION 'Business type is required.';
END IF;
    IF NOT EXISTS (SELECT 1 FROM business_types WHERE id = p_business_type_id AND is_active) THEN
        RAISE EXCEPTION 'Business type not found or inactive.';
END IF;

INSERT INTO items (
    name, business_type_id, category, unit, reorder_level, requires_prescription
) VALUES (
             trim(p_name),
             p_business_type_id,
             NULLIF(trim(p_category), ''),
             COALESCE(NULLIF(trim(p_unit), ''), 'unit'),
             COALESCE(p_reorder_level, 10),
             COALESCE(p_requires_prescription, false)
         ) RETURNING id INTO v_item_id;

RETURN v_item_id;
END;
$$;

-- 5. Readable view for the admin screen and the cashier's own status
CREATE OR REPLACE VIEW v_catalog_access_requests WITH (security_invoker = true) AS
SELECT g.id, g.user_id, u.full_name, g.branch_id, b.name AS branch_name,
       g.reason, g.requested_at, g.decided_at, g.expires_at, g.revoked_at,
       d.full_name AS decided_by_name, r.full_name AS revoked_by_name,
       g.revoked_by AS revoked_by_id,
       CASE WHEN g.status = 'approved' AND g.expires_at IS NOT NULL AND g.expires_at <= now()
                THEN 'expired' ELSE g.status::text END AS effective_status
FROM catalog_access_grants g
         JOIN users u ON u.id = g.user_id
         JOIN branches b ON b.id = g.branch_id
         LEFT JOIN users d ON d.id = g.decided_by
         LEFT JOIN users r ON r.id = g.revoked_by
ORDER BY g.requested_at DESC;

-- Permissions
REVOKE ALL ON FUNCTION request_catalog_access(text)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION decide_catalog_access(uuid, boolean, int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION revoke_catalog_access(uuid)               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION has_catalog_access()                      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION add_catalog_item(text, uuid, text, text, numeric, boolean) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION request_catalog_access(text)              TO authenticated;
GRANT EXECUTE ON FUNCTION decide_catalog_access(uuid, boolean, int) TO authenticated;
GRANT EXECUTE ON FUNCTION revoke_catalog_access(uuid)               TO authenticated;
GRANT EXECUTE ON FUNCTION has_catalog_access()                      TO authenticated;
GRANT EXECUTE ON FUNCTION add_catalog_item(text, uuid, text, text, numeric, boolean) TO authenticated;

-- Make the API pick up the new functions straight away
NOTIFY pgrst, 'reload schema';


       -- ============================================================================
-- FRACTIONAL / MULTI-UNIT QUANTITIES
-- Run after all earlier migrations. Safe to re-run.
--
-- Idea: every quantity in the system (inventory, sale_items, stock_movements,
-- purchase_items) is stored in the item's BASE UNIT = the smallest thing you
-- would ever sell: tablet, ml, g, piece. items.unit already exists, so it
-- simply becomes "the base unit". Nothing existing breaks: old items keep
-- their unit and a step of 1.
--
--   Paracetamol syrup : unit 'ml',     step 1,   bottle = 100 ml
--   Amoxicillin       : unit 'tablet', step 1,   strip = 10, box = 100
--   Powder / herbs    : unit 'g',      step 1,   kg = 1000
--
-- Prices (buying_price, retail_price, wholesale_price, unit_price, unit_cost)
-- are then PER BASE UNIT. A 100 ml bottle at MWK 1,500 is 15.00 per ml.
-- The app shows "per bottle" by multiplying by the unit factor.
--
-- Quantity columns are already NUMERIC(12,2), so 0.01 precision is available
-- without altering any column (changing types would force dropping views).
-- ============================================================================

-- 1. Per-item rules ------------------------------------------------------------
-- quantity_step = smallest sellable amount, and every quantity must be a
-- multiple of it. 1 = whole units only (the default, same as today).
-- 0.5 = halves allowed. 10 = sold only in tens of the base unit.
ALTER TABLE items
    ADD COLUMN IF NOT EXISTS quantity_step NUMERIC(12,2) NOT NULL DEFAULT 1;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'items_quantity_step_positive') THEN
ALTER TABLE items ADD CONSTRAINT items_quantity_step_positive CHECK (quantity_step > 0);
END IF;
END
$$;

-- 2. Bigger units that convert into the base unit -----------------------------
CREATE TABLE IF NOT EXISTS item_units (
                                          id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id     uuid NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    unit_name   text NOT NULL,                       -- 'bottle', 'box', 'strip', 'kg'
    factor      NUMERIC(12,2) NOT NULL CHECK (factor > 0),  -- how many base units in one
    created_at  timestamptz NOT NULL DEFAULT now()
    );
CREATE UNIQUE INDEX IF NOT EXISTS uq_item_units_name
    ON item_units (item_id, lower(trim(unit_name)));

ALTER TABLE item_units ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View item units with the item" ON item_units;
CREATE POLICY "View item units with the item"
    ON item_units FOR SELECT
                                      USING (EXISTS (SELECT 1 FROM items i WHERE i.id = item_units.item_id));  -- items RLS applies

DROP POLICY IF EXISTS "Admins manage item units" ON item_units;
CREATE POLICY "Admins manage item units"
    ON item_units FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- 3. Conversion helper: "5 boxes" -> 500 tablets -------------------------------
-- Pass the base unit name (or NULL) to get the quantity back unchanged.
CREATE OR REPLACE FUNCTION to_base_qty(p_item_id uuid, p_unit_name text, p_qty numeric)
RETURNS numeric
LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE v_base text; v_factor numeric;
BEGIN
SELECT unit INTO v_base FROM items WHERE id = p_item_id;
IF v_base IS NULL THEN RAISE EXCEPTION 'Item not found.'; END IF;
  IF p_unit_name IS NULL OR lower(trim(p_unit_name)) = lower(trim(v_base)) THEN
    RETURN p_qty;
END IF;
SELECT factor INTO v_factor FROM item_units
WHERE item_id = p_item_id AND lower(trim(unit_name)) = lower(trim(p_unit_name));
IF v_factor IS NULL THEN
    RAISE EXCEPTION 'No unit "%" is set up for this item.', p_unit_name;
END IF;
RETURN p_qty * v_factor;
END;
$$;
REVOKE ALL ON FUNCTION to_base_qty(uuid, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION to_base_qty(uuid, text, numeric) TO authenticated;

-- 4. Enforce the step everywhere, whatever the app does ------------------------
-- A trigger (not a change to create_sale) so receive_stock_delivery, direct
-- inserts and future code are all covered, and create_sale needs no rewrite.
CREATE OR REPLACE FUNCTION fn_enforce_quantity_step() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
v_qty  numeric := (to_jsonb(NEW) ->> TG_ARGV[0])::numeric;
  v_step numeric;
  v_name text;
  v_unit text;
BEGIN
SELECT quantity_step, name, unit INTO v_step, v_name, v_unit
FROM items WHERE id = NEW.item_id;
IF v_qty IS NOT NULL AND v_step IS NOT NULL AND (v_qty % v_step) <> 0 THEN
    RAISE EXCEPTION '% can only be handled in steps of % % (got %).',
                    v_name, v_step, v_unit, v_qty;
END IF;
RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_step_sale_items ON sale_items;
CREATE TRIGGER trg_step_sale_items
    BEFORE INSERT ON sale_items
    FOR EACH ROW EXECUTE FUNCTION fn_enforce_quantity_step('quantity');

DROP TRIGGER IF EXISTS trg_step_inventory ON inventory;
CREATE TRIGGER trg_step_inventory
    BEFORE INSERT ON inventory
    FOR EACH ROW EXECUTE FUNCTION fn_enforce_quantity_step('quantity_received');

-- 5. Keep subtotals honest when prices are per small unit ----------------------
-- create_sale already writes subtotal = quantity * unit_price. Both are
-- 2-decimal, so the product can have 4 decimals; the column rounds it to 2.
-- Nothing to change. Just be aware that a price like 4.1667/g is stored as 4.17.

-- 6. Examples (edit names; run by hand if you want them) -----------------------
-- UPDATE items SET unit = 'ml'  WHERE name ILIKE '%SYRUP%';
-- UPDATE items SET unit = 'g', quantity_step = 1 WHERE name ILIKE '%POWDER%';
-- INSERT INTO item_units (item_id, unit_name, factor)
--   SELECT id, 'bottle', 100 FROM items WHERE name = 'PARACETAMOL SYRUP 100ML';
--
-- IMPORTANT: if an item already has stock counted in bottles, convert that
-- stock and its prices when you change its unit, e.g. for a 100 ml bottle:
--   UPDATE inventory SET quantity_received  = quantity_received  * 100,
--                        quantity_available = quantity_available * 100,
--                        buying_price   = buying_price   / 100,
--                        retail_price   = retail_price   / 100,
--                        wholesale_price = wholesale_price / 100
--   WHERE item_id = '<item id>';
-- (past sale_items / stock_movements stay as history in the old unit.)

NOTIFY pgrst, 'reload schema';

       -- ============================================================================
-- FRACTIONAL QUANTITIES — PART 2
-- Run AFTER fractional_quantities.sql. Safe to re-run.
--   1. get_receipt() now returns each line's unit (receipts print "50 ml").
--   2. admin_convert_item_unit(): safely switches an item that already has
--      stock to a smaller base unit (bottle -> ml, kg -> g, box -> tablet),
--      converting stock quantities, buying/selling prices and reorder level
--      in one transaction, and remembering the old unit as a conversion.
-- ============================================================================

-- 1. Receipt with units ----------------------------------------------------------
CREATE OR REPLACE FUNCTION get_receipt(p_sale_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r jsonb;
BEGIN
SELECT jsonb_build_object(
               'sale_id',         s.id,
               'receipt_number',  s.receipt_number,
               'sale_date',       s.sale_date AT TIME ZONE 'Africa/Blantyre',
               'branch_name',     b.name,
               'branch_location', b.location,
               'branch_phone',    b.phone,
               'cashier_name',    u.full_name,
               'customer_name',   c.name,
               'sale_type',       s.sale_type,
               'payment_method',  s.payment_method,
               'payment_status',  s.payment_status,
               'total_amount',    s.total_amount,
               'amount_paid',     s.amount_paid,
               'balance_due',     s.total_amount - s.amount_paid,
               'items', COALESCE((
                                     SELECT jsonb_agg(jsonb_build_object(
                                                              'name', i.name, 'unit', i.unit,
                                                              'quantity', si.quantity,
                                                              'unit_price', si.unit_price, 'subtotal', si.subtotal)
                                                          ORDER BY i.name, si.id)
                                     FROM sale_items si JOIN items i ON i.id = si.item_id
                                     WHERE si.sale_id = s.id), '[]'::jsonb)
       ) INTO r
FROM sales s
         JOIN branches b ON b.id = s.branch_id
         LEFT JOIN users u ON u.id = s.cashier_id
         LEFT JOIN customers c ON c.id = s.customer_id
WHERE s.id = p_sale_id
  AND (is_admin() OR s.branch_id = user_branch_id());

IF r IS NULL THEN RAISE EXCEPTION 'Receipt not found.'; END IF;
RETURN r;
END;
$$;

-- 2. Convert an item that already has stock to a smaller base unit ----------------
-- p_factor = how many NEW base units are in ONE OLD unit.
--   Syrup counted in bottles of 100 ml:  admin_convert_item_unit(id, 'ml', 100)
--   Sugar counted in kg:                 admin_convert_item_unit(id, 'g', 1000)
--   Tablets counted in boxes of 100:     admin_convert_item_unit(id, 'tablet', 100)
-- Past sales / movements stay as history in the old unit.
CREATE OR REPLACE FUNCTION admin_convert_item_unit(
    p_item_id uuid, p_new_unit text, p_factor numeric, p_step numeric DEFAULT 1
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
v_old text;
  v_bad int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Only admins can change an item''s unit.'; END IF;
  IF p_factor IS NULL OR p_factor <= 0 THEN RAISE EXCEPTION 'The conversion must be above zero.'; END IF;
  IF p_step IS NULL OR p_step <= 0 THEN RAISE EXCEPTION 'The smallest sale step must be above zero.'; END IF;
  IF trim(COALESCE(p_new_unit, '')) = '' THEN RAISE EXCEPTION 'Enter the new unit name.'; END IF;

SELECT unit INTO v_old FROM items WHERE id = p_item_id FOR UPDATE;
IF v_old IS NULL THEN RAISE EXCEPTION 'Item not found.'; END IF;
  IF lower(trim(v_old)) = lower(trim(p_new_unit)) THEN
    RAISE EXCEPTION 'The item is already counted in %.', v_old;
END IF;

  -- Prices are stored to 2 decimals. Refuse if splitting would distort any
  -- price by more than 1% (e.g. MK 1 per box of 300 would become 0.00).
SELECT count(*) INTO v_bad FROM inventory
WHERE item_id = p_item_id
  AND ((retail_price   > 0 AND abs(round(retail_price   / p_factor, 2) * p_factor - retail_price)   / retail_price   > 0.01)
    OR (buying_price   > 0 AND abs(round(buying_price   / p_factor, 2) * p_factor - buying_price)   / buying_price   > 0.01)
    OR (wholesale_price > 0 AND abs(round(wholesale_price / p_factor, 2) * p_factor - wholesale_price) / wholesale_price > 0.01));
IF v_bad > 0 THEN
    RAISE EXCEPTION 'Some prices are too small to split into % without losing accuracy.', p_new_unit;
END IF;

UPDATE inventory SET
                     quantity_received  = quantity_received  * p_factor,
                     quantity_available = quantity_available * p_factor,
                     buying_price       = round(buying_price   / p_factor, 2),
                     retail_price       = round(retail_price   / p_factor, 2),
                     wholesale_price    = round(wholesale_price / p_factor, 2)
WHERE item_id = p_item_id;

UPDATE items SET
                 unit          = trim(p_new_unit),
                 reorder_level = reorder_level * p_factor,
                 quantity_step = p_step
WHERE id = p_item_id;

-- Remember the old unit so staff can still receive "5 bottles".
DELETE FROM item_units WHERE item_id = p_item_id AND lower(trim(unit_name)) = lower(trim(v_old));
INSERT INTO item_units (item_id, unit_name, factor) VALUES (p_item_id, trim(v_old), p_factor);
END;
$$;

REVOKE ALL ON FUNCTION admin_convert_item_unit(uuid, text, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_convert_item_unit(uuid, text, numeric, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

       -- ============================================================================
-- FRACTIONAL QUANTITIES + UNITS: apply to create_sale, receive_stock_delivery
-- Run in Supabase SQL editor. Safe to re-run (CREATE OR REPLACE + IF EXISTS).
-- ============================================================================

-- 1. create_sale: read "unit" per line, convert to base units, store unit ----
CREATE OR REPLACE FUNCTION create_sale(
    p_lines          jsonb,
    p_sale_type      sale_type      DEFAULT 'retail',
    p_payment_method payment_method DEFAULT 'cash',
    p_customer_id    uuid           DEFAULT NULL,
    p_amount_paid    numeric        DEFAULT 0,
    p_paid_method    payment_method DEFAULT 'cash',
    p_branch_id      uuid           DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
v_uid       uuid := auth.uid();
    v_today     date := (now() AT TIME ZONE 'Africa/Blantyre')::date;
    v_role      user_role;
    v_branch    uuid;
    v_prefix    text;
    v_sale_id   uuid;
    v_line      record;
    v_batch     record;
    v_item_name text;
    v_remaining numeric;
    v_take      numeric;
    v_price     numeric;
    v_total     numeric;
BEGIN
SELECT role, branch_id INTO v_role, v_branch FROM users WHERE id = v_uid AND is_active;
IF v_role IS NULL THEN RAISE EXCEPTION 'Your account is not active.'; END IF;
    IF v_role = 'admin' THEN
        v_branch := p_branch_id;
        IF v_branch IS NULL THEN RAISE EXCEPTION 'Choose a branch to sell from.'; END IF;
    ELSIF v_role NOT IN ('cashier', 'manager') THEN
        RAISE EXCEPTION 'Your role cannot record sales.';
END IF;
    IF NOT EXISTS (SELECT 1 FROM branches WHERE id = v_branch AND is_active) THEN
        RAISE EXCEPTION 'Branch not found or inactive.';
END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one item to the sale.';
END IF;
    IF p_payment_method = 'credit' AND p_customer_id IS NULL THEN
        RAISE EXCEPTION 'A customer is required for credit sales.';
END IF;
    IF p_customer_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM customers WHERE id = p_customer_id
           AND (branch_id IS NULL OR branch_id = v_branch)) THEN
        RAISE EXCEPTION 'Customer not found at this branch.';
END IF;

SELECT upper(left(regexp_replace(name, '[^A-Za-z]', '', 'g'), 3))
INTO v_prefix FROM branches WHERE id = v_branch;
INSERT INTO sales (branch_id, customer_id, cashier_id, sale_type, payment_method,
                   payment_status, receipt_number)
VALUES (v_branch, p_customer_id, v_uid, p_sale_type, p_payment_method,
        CASE WHEN p_payment_method = 'credit'
                 THEN 'pending'::payment_status ELSE 'paid'::payment_status END,
        COALESCE(NULLIF(v_prefix, ''), 'RCT') || '-' || lpad(nextval('receipt_seq')::text, 6, '0'))
    RETURNING id INTO v_sale_id;

-- Each line may carry a "unit" (e.g. "bottle"); convert to base units.
FOR v_line IN
SELECT (l->>'item_id')::uuid AS item_id,
    SUM((l->>'quantity')::numeric) AS qty,
       COALESCE(NULLIF(l->>'unit', ''), NULL) AS unit_name
FROM jsonb_array_elements(p_lines) AS l
GROUP BY 1, 3 ORDER BY 1
    LOOP
        IF v_line.qty <= 0 THEN RAISE EXCEPTION 'Quantities must be greater than zero.'; END IF;

SELECT name INTO v_item_name FROM items WHERE id = v_line.item_id AND is_active;
IF v_item_name IS NULL THEN RAISE EXCEPTION 'An item in this sale is missing or discontinued.'; END IF;

        -- Convert to the item's base unit (inventory is always counted in base).
        v_remaining := to_base_qty(v_line.item_id, COALESCE(v_line.unit_name, ''), v_line.qty);

FOR v_batch IN
SELECT id, buying_price, retail_price, wholesale_price, quantity_available
FROM inventory
WHERE branch_id = v_branch AND item_id = v_line.item_id
  AND quantity_available > 0
  AND (expiry_date IS NULL OR expiry_date >= v_today)
ORDER BY expiry_date ASC NULLS LAST, received_date ASC, created_at ASC
    FOR UPDATE
    LOOP
            EXIT WHEN v_remaining <= 0;
v_take  := LEAST(v_remaining, v_batch.quantity_available);
            v_price := CASE WHEN p_sale_type = 'wholesale'
                            THEN COALESCE(v_batch.wholesale_price, v_batch.retail_price)
                            ELSE v_batch.retail_price END;

INSERT INTO sale_items (sale_id, item_id, inventory_id, quantity,
                        unit_price, unit_cost, subtotal, unit)
VALUES (v_sale_id, v_line.item_id, v_batch.id, v_take,
        v_price, v_batch.buying_price, v_take * v_price, v_line.unit_name);

UPDATE inventory SET quantity_available = quantity_available - v_take
WHERE id = v_batch.id;

INSERT INTO stock_movements (branch_id, item_id, inventory_id, movement_type,
                             quantity, reference_table, reference_id, performed_by)
VALUES (v_branch, v_line.item_id, v_batch.id, 'sale_out',
        v_take, 'sales', v_sale_id, v_uid);

v_remaining := v_remaining - v_take;
END LOOP;

        IF v_remaining > 0 THEN
            RAISE EXCEPTION 'Not enough stock for %: only % available.',
                            v_item_name, v_line.qty - v_remaining;
END IF;
END LOOP;

SELECT total_amount INTO v_total FROM sales WHERE id = v_sale_id;

IF p_payment_method = 'credit' THEN
        IF COALESCE(p_amount_paid, 0) < 0 OR COALESCE(p_amount_paid, 0) > v_total THEN
            RAISE EXCEPTION 'Amount paid now must be between 0 and the sale total.';
END IF;
        IF COALESCE(p_amount_paid, 0) > 0 THEN
            IF p_paid_method = 'credit' THEN
                RAISE EXCEPTION 'Choose how the part-payment was made (cash, mobile money or card).';
END IF;
INSERT INTO payments (branch_id, customer_id, sale_id, amount, payment_method,
                      recorded_by, notes)
VALUES (v_branch, p_customer_id, v_sale_id, p_amount_paid, p_paid_method,
        v_uid, 'Part-payment at time of sale');
END IF;
ELSE
UPDATE sales SET amount_paid = total_amount WHERE id = v_sale_id;
END IF;

RETURN get_receipt(v_sale_id);
END;
$$;


-- 2. receive_stock_delivery: convert "unit" per line to base units -----------
CREATE OR REPLACE FUNCTION receive_stock_delivery(
    p_branch_id uuid,
    p_supplier_id uuid DEFAULT NULL,
    p_invoice_number text DEFAULT NULL,
    p_purchase_date date DEFAULT current_date,
    p_lines jsonb DEFAULT '[]'::jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
v_uid uuid := auth.uid();
    v_role user_role;
    v_user_branch uuid;
    v_purchase_id uuid;
    v_line jsonb;
    v_item_id uuid;
    v_inventory_id uuid;
    v_qty numeric;
    v_buying numeric;
    v_retail numeric;
    v_wholesale numeric;
    v_expiry date;
    v_batch text;
BEGIN
SELECT role, branch_id INTO v_role, v_user_branch
FROM users WHERE id = v_uid AND is_active;
IF v_role IS NULL THEN RAISE EXCEPTION 'Your account is not active.'; END IF;
    IF p_branch_id IS NULL THEN RAISE EXCEPTION 'Choose a branch.'; END IF;
    IF v_role = 'cashier' THEN
        IF v_user_branch IS DISTINCT FROM p_branch_id OR NOT has_stock_access() THEN
            RAISE EXCEPTION 'Active stock access is required to receive stock at your branch.';
END IF;
    ELSIF v_role NOT IN ('admin', 'manager', 'stock_controller') THEN
        RAISE EXCEPTION 'Your role cannot receive stock.';
END IF;
    IF NOT EXISTS (SELECT 1 FROM branches WHERE id = p_branch_id AND is_active) THEN
        RAISE EXCEPTION 'Branch not found or inactive.';
END IF;
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one delivery line.';
END IF;
    IF p_supplier_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND is_active
    ) THEN
        RAISE EXCEPTION 'Supplier not found or inactive.';
END IF;

INSERT INTO purchases (branch_id, supplier_id, invoice_number, payment_status,
                       purchase_date, created_by)
VALUES (p_branch_id, p_supplier_id, NULLIF(trim(p_invoice_number), ''),
        CASE WHEN p_supplier_id IS NULL THEN 'paid'::payment_status
             ELSE 'pending'::payment_status END,
        COALESCE(p_purchase_date, current_date), v_uid)
    RETURNING id INTO v_purchase_id;

FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
                                    LOOP
    v_item_id := (v_line->>'item_id')::uuid;
v_qty := (v_line->>'quantity')::numeric;
        v_buying := (v_line->>'buying_price')::numeric;
        v_retail := (v_line->>'retail_price')::numeric;
        v_wholesale := NULLIF(v_line->>'wholesale_price', '')::numeric;
        v_expiry := NULLIF(v_line->>'expiry_date', '')::date;
        v_batch := NULLIF(trim(v_line->>'batch_number'), '');

        IF v_qty IS NULL OR v_qty <= 0 OR v_buying IS NULL OR v_buying < 0
           OR v_retail IS NULL OR v_retail < 0 THEN
            RAISE EXCEPTION 'Each delivery line needs valid quantity and prices.';
END IF;
        IF v_wholesale IS NOT NULL AND v_wholesale < 0 THEN
            RAISE EXCEPTION 'Wholesale prices cannot be negative.';
END IF;
        IF v_expiry IS NOT NULL AND v_expiry < current_date THEN
            RAISE EXCEPTION 'Expiry dates cannot be in the past.';
END IF;
        IF NOT EXISTS (SELECT 1 FROM items WHERE id = v_item_id AND is_active) THEN
            RAISE EXCEPTION 'An item is missing or discontinued.';
END IF;

        -- A bigger unit ("2 bottles") converts to base units ("200 ml").
        -- Prices are per base unit and must NOT be scaled.
        v_qty := to_base_qty(v_item_id, COALESCE(NULLIF(trim(v_line->>'unit'), ''), ''), v_qty);

INSERT INTO inventory (item_id, branch_id, batch_number, buying_price, retail_price,
                       wholesale_price, quantity_received, quantity_available,
                       expiry_date, received_date, created_by)
VALUES (v_item_id, p_branch_id, v_batch, v_buying, v_retail,
        v_wholesale, v_qty, v_qty, v_expiry,
        COALESCE(p_purchase_date, current_date), v_uid)
    RETURNING id INTO v_inventory_id;

INSERT INTO purchase_items (purchase_id, item_id, inventory_id, quantity, unit_cost, subtotal)
VALUES (v_purchase_id, v_item_id, v_inventory_id, v_qty, v_buying, v_qty * v_buying);

INSERT INTO stock_movements (branch_id, item_id, inventory_id, movement_type, quantity,
                             reference_table, reference_id, performed_by, notes)
VALUES (p_branch_id, v_item_id, v_inventory_id, 'purchase_in', v_qty,
        'purchases', v_purchase_id, v_uid, 'Received delivery');
END LOOP;
RETURN v_purchase_id;
END;
$$;


NOTIFY pgrst, 'reload schema';

