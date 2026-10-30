--
-- PostgreSQL database dump
--

\restrict G7S9XdhSDHSfHHrZmfweIyO5abyLWFhD3JRoUSLDj8Jj2bIcSE46L7eXylBCGGP

-- Dumped from database version 16.15 (Debian 16.15-1.pgdg13+2)
-- Dumped by pg_dump version 16.15 (Debian 16.15-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id bigint NOT NULL,
    actor_id uuid,
    action text NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_logs_id_seq OWNED BY public.audit_logs.id;


--
-- Name: locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.locations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    zone_id uuid NOT NULL,
    code text NOT NULL,
    capacity_pallets integer DEFAULT 1 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    CONSTRAINT locations_capacity_pallets_check CHECK ((capacity_pallets > 0))
);


--
-- Name: lots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    lot_number text NOT NULL,
    expiry_date date,
    production_date date
);


--
-- Name: master_data_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.master_data_audit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_id uuid NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid NOT NULL,
    action text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT master_data_audit_entity_type_check CHECK ((entity_type = ANY (ARRAY['CUSTOMER'::text, 'SUPPLIER'::text])))
);


--
-- Name: order_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    product_id uuid NOT NULL,
    ordered_qty numeric(16,3) NOT NULL,
    picked_qty numeric(16,3) DEFAULT 0 NOT NULL,
    CONSTRAINT order_lines_ordered_qty_check CHECK ((ordered_qty > (0)::numeric)),
    CONSTRAINT order_lines_picked_qty_check CHECK ((picked_qty >= (0)::numeric))
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    external_ref text,
    destination text NOT NULL,
    required_at timestamp with time zone,
    status text DEFAULT 'NEW'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT orders_status_check CHECK ((status = ANY (ARRAY['NEW'::text, 'ALLOCATED'::text, 'PICKING'::text, 'PACKED'::text, 'SHIPPED'::text, 'CANCELLED'::text])))
);


--
-- Name: pallet_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pallet_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    pallet_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    product_id uuid NOT NULL,
    lot_id uuid NOT NULL,
    qty numeric(16,3) NOT NULL,
    reserved_qty numeric(16,3) DEFAULT 0 NOT NULL,
    CONSTRAINT pallet_items_check CHECK (((reserved_qty >= (0)::numeric) AND (reserved_qty <= qty))),
    CONSTRAINT pallet_items_qty_check CHECK ((qty >= (0)::numeric))
);


--
-- Name: pallets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pallets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    lpn text NOT NULL,
    tenant_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    location_id uuid,
    status text DEFAULT 'RECEIVING'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pallets_status_check CHECK ((status = ANY (ARRAY['RECEIVING'::text, 'AVAILABLE'::text, 'RESERVED'::text, 'QUARANTINE'::text, 'SHIPPED'::text])))
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    sku text NOT NULL,
    name text NOT NULL,
    barcode text,
    base_uom text NOT NULL,
    regime text NOT NULL,
    shelf_life_days integer,
    units_per_case integer,
    case_weight_kg numeric(14,3),
    cases_per_pallet integer,
    net_weight_kg numeric(14,3),
    gross_weight_kg numeric(14,3),
    expiry_warning_days integer DEFAULT 30 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    CONSTRAINT product_weight_order_v09 CHECK (((net_weight_kg IS NULL) OR (gross_weight_kg IS NULL) OR (gross_weight_kg >= net_weight_kg))),
    CONSTRAINT products_case_weight_kg_check CHECK ((case_weight_kg > (0)::numeric)),
    CONSTRAINT products_cases_per_pallet_check CHECK ((cases_per_pallet >= 1)),
    CONSTRAINT products_expiry_warning_days_check CHECK (((expiry_warning_days >= 0) AND (expiry_warning_days <= 3650))),
    CONSTRAINT products_gross_weight_kg_check CHECK ((gross_weight_kg > (0)::numeric)),
    CONSTRAINT products_net_weight_kg_check CHECK ((net_weight_kg > (0)::numeric)),
    CONSTRAINT products_regime_check CHECK ((regime = ANY (ARRAY['FROZEN'::text, 'CHILLED'::text, 'AMBIENT'::text, 'SHOCK'::text]))),
    CONSTRAINT products_units_per_case_check CHECK ((units_per_case >= 1))
);


--
-- Name: receipt_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receipt_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    receipt_id uuid NOT NULL,
    product_id uuid NOT NULL,
    expected_qty numeric(16,3) NOT NULL,
    accepted_qty numeric(16,3) DEFAULT 0 NOT NULL,
    rejected_qty numeric(16,3) DEFAULT 0 NOT NULL,
    lot_number text,
    expiry_date date,
    measured_temp numeric(5,2),
    rejection_reason text,
    CONSTRAINT receipt_lines_accepted_qty_check CHECK ((accepted_qty >= (0)::numeric)),
    CONSTRAINT receipt_lines_expected_qty_check CHECK ((expected_qty >= (0)::numeric)),
    CONSTRAINT receipt_lines_rejected_qty_check CHECK ((rejected_qty >= (0)::numeric))
);


--
-- Name: receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    warehouse_id uuid NOT NULL,
    document_no text NOT NULL,
    supplier text,
    supplier_id uuid,
    status text DEFAULT 'DRAFT'::text NOT NULL,
    arrived_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT receipts_status_check CHECK ((status = ANY (ARRAY['DRAFT'::text, 'INSPECTION'::text, 'ACCEPTED'::text, 'PARTIAL'::text, 'REJECTED'::text])))
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL
);


--
-- Name: shipment_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shipment_orders (
    shipment_id uuid NOT NULL,
    order_id uuid NOT NULL
);


--
-- Name: shipments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shipments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    warehouse_id uuid NOT NULL,
    plate text,
    driver_name text,
    route_code text,
    status text DEFAULT 'PLANNED'::text NOT NULL,
    departed_at timestamp with time zone,
    CONSTRAINT shipments_status_check CHECK ((status = ANY (ARRAY['PLANNED'::text, 'LOADING'::text, 'DISPATCHED'::text, 'DELIVERED'::text])))
);


--
-- Name: stock_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_movements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    product_id uuid NOT NULL,
    lot_id uuid,
    pallet_id uuid,
    from_location_id uuid,
    to_location_id uuid,
    qty numeric(16,3) NOT NULL,
    movement_type text NOT NULL,
    reference_id uuid,
    actor_id uuid,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stock_movements_movement_type_check CHECK ((movement_type = ANY (ARRAY['RECEIPT'::text, 'PUTAWAY'::text, 'TRANSFER'::text, 'PICK'::text, 'SHIP'::text, 'RETURN'::text, 'ADJUSTMENT'::text, 'QUARANTINE'::text]))),
    CONSTRAINT stock_movements_qty_check CHECK ((qty > (0)::numeric))
);


--
-- Name: supplier_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_products (
    tenant_id uuid NOT NULL,
    supplier_id uuid NOT NULL,
    product_id uuid NOT NULL
);


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suppliers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    tax_number text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: temperature_readings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.temperature_readings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    zone_id uuid,
    shipment_id uuid,
    temperature_c numeric(5,2) NOT NULL,
    source text NOT NULL,
    measured_at timestamp with time zone NOT NULL,
    CONSTRAINT temperature_readings_check CHECK (((zone_id IS NOT NULL) <> (shipment_id IS NOT NULL)))
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    tax_number text,
    customer_code text NOT NULL,
    legal_name text NOT NULL,
    tax_office text,
    contact_person text,
    phone text,
    email text,
    address text,
    regimes text[] NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tenants_regimes_check CHECK (((cardinality(regimes) > 0) AND (regimes <@ ARRAY['FROZEN'::text, 'CHILLED'::text, 'AMBIENT'::text, 'SHOCK'::text])))
);


--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_roles (
    user_id uuid NOT NULL,
    role_id uuid NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    password_hash text NOT NULL,
    full_name text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: warehouses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.warehouses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    address text
);


--
-- Name: zones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.zones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    warehouse_id uuid NOT NULL,
    code text NOT NULL,
    regime text NOT NULL,
    min_temp numeric(5,2),
    max_temp numeric(5,2),
    CONSTRAINT zones_regime_check CHECK ((regime = ANY (ARRAY['FROZEN'::text, 'CHILLED'::text, 'AMBIENT'::text, 'SHOCK'::text, 'QUARANTINE'::text])))
);


--
-- Name: audit_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs ALTER COLUMN id SET DEFAULT nextval('public.audit_logs_id_seq'::regclass);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: locations locations_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_code_key UNIQUE (code);


--
-- Name: locations locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (id);


--
-- Name: lots lots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_pkey PRIMARY KEY (id);


--
-- Name: lots lots_product_id_lot_number_expiry_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_product_id_lot_number_expiry_date_key UNIQUE (product_id, lot_number, expiry_date);


--
-- Name: master_data_audit master_data_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_data_audit
    ADD CONSTRAINT master_data_audit_pkey PRIMARY KEY (id);


--
-- Name: order_lines order_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_lines
    ADD CONSTRAINT order_lines_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: pallet_items pallet_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallet_items
    ADD CONSTRAINT pallet_items_pkey PRIMARY KEY (id);


--
-- Name: pallets pallets_id_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallets
    ADD CONSTRAINT pallets_id_tenant_id_key UNIQUE (id, tenant_id);


--
-- Name: pallets pallets_lpn_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallets
    ADD CONSTRAINT pallets_lpn_key UNIQUE (lpn);


--
-- Name: pallets pallets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallets
    ADD CONSTRAINT pallets_pkey PRIMARY KEY (id);


--
-- Name: products products_id_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_id_tenant_id_key UNIQUE (id, tenant_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: products products_tenant_id_sku_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_tenant_id_sku_key UNIQUE (tenant_id, sku);


--
-- Name: receipt_lines receipt_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_lines
    ADD CONSTRAINT receipt_lines_pkey PRIMARY KEY (id);


--
-- Name: receipts receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_pkey PRIMARY KEY (id);


--
-- Name: receipts receipts_tenant_id_document_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_tenant_id_document_no_key UNIQUE (tenant_id, document_no);


--
-- Name: roles roles_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_code_key UNIQUE (code);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: shipment_orders shipment_orders_order_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipment_orders
    ADD CONSTRAINT shipment_orders_order_id_key UNIQUE (order_id);


--
-- Name: shipment_orders shipment_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipment_orders
    ADD CONSTRAINT shipment_orders_pkey PRIMARY KEY (shipment_id, order_id);


--
-- Name: shipments shipments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_pkey PRIMARY KEY (id);


--
-- Name: stock_movements stock_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (id);


--
-- Name: supplier_products supplier_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT supplier_products_pkey PRIMARY KEY (supplier_id, product_id);


--
-- Name: suppliers suppliers_id_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_id_tenant_id_key UNIQUE (id, tenant_id);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id);


--
-- Name: suppliers suppliers_tenant_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_tenant_id_code_key UNIQUE (tenant_id, code);


--
-- Name: temperature_readings temperature_readings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.temperature_readings
    ADD CONSTRAINT temperature_readings_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_customer_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_customer_code_key UNIQUE (customer_code);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_tax_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_tax_number_key UNIQUE (tax_number);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (user_id, role_id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: warehouses warehouses_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_code_key UNIQUE (code);


--
-- Name: warehouses warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_pkey PRIMARY KEY (id);


--
-- Name: zones zones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zones
    ADD CONSTRAINT zones_pkey PRIMARY KEY (id);


--
-- Name: zones zones_warehouse_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zones
    ADD CONSTRAINT zones_warehouse_id_code_key UNIQUE (warehouse_id, code);


--
-- Name: idx_lots_fefo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lots_fefo ON public.lots USING btree (product_id, expiry_date);


--
-- Name: idx_movements_tenant_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_movements_tenant_time ON public.stock_movements USING btree (tenant_id, occurred_at DESC);


--
-- Name: idx_orders_tenant_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_orders_tenant_status ON public.orders USING btree (tenant_id, status);


--
-- Name: idx_pallet_items_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pallet_items_product ON public.pallet_items USING btree (product_id);


--
-- Name: idx_receipts_tenant_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_receipts_tenant_time ON public.receipts USING btree (tenant_id, created_at DESC);


--
-- Name: idx_suppliers_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_suppliers_customer ON public.suppliers USING btree (tenant_id, active);


--
-- Name: ux_product_barcode_per_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_product_barcode_per_customer ON public.products USING btree (tenant_id, barcode) WHERE ((barcode IS NOT NULL) AND (barcode <> ''::text));


--
-- Name: audit_logs audit_logs_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: locations locations_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES public.zones(id);


--
-- Name: lots lots_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: master_data_audit master_data_audit_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_data_audit
    ADD CONSTRAINT master_data_audit_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: order_lines order_lines_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_lines
    ADD CONSTRAINT order_lines_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: order_lines order_lines_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_lines
    ADD CONSTRAINT order_lines_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: orders orders_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: orders orders_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: pallet_items pallet_items_lot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallet_items
    ADD CONSTRAINT pallet_items_lot_id_fkey FOREIGN KEY (lot_id) REFERENCES public.lots(id);


--
-- Name: pallet_items pallet_items_pallet_id_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallet_items
    ADD CONSTRAINT pallet_items_pallet_id_tenant_id_fkey FOREIGN KEY (pallet_id, tenant_id) REFERENCES public.pallets(id, tenant_id);


--
-- Name: pallet_items pallet_items_product_id_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallet_items
    ADD CONSTRAINT pallet_items_product_id_tenant_id_fkey FOREIGN KEY (product_id, tenant_id) REFERENCES public.products(id, tenant_id);


--
-- Name: pallets pallets_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallets
    ADD CONSTRAINT pallets_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.locations(id);


--
-- Name: pallets pallets_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallets
    ADD CONSTRAINT pallets_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: pallets pallets_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pallets
    ADD CONSTRAINT pallets_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: products products_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receipt_lines receipt_lines_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_lines
    ADD CONSTRAINT receipt_lines_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: receipt_lines receipt_lines_receipt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_lines
    ADD CONSTRAINT receipt_lines_receipt_id_fkey FOREIGN KEY (receipt_id) REFERENCES public.receipts(id);


--
-- Name: receipts receipt_supplier_same_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipt_supplier_same_tenant FOREIGN KEY (supplier_id, tenant_id) REFERENCES public.suppliers(id, tenant_id);


--
-- Name: receipts receipts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: receipts receipts_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: receipts receipts_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: shipment_orders shipment_orders_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipment_orders
    ADD CONSTRAINT shipment_orders_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: shipment_orders shipment_orders_shipment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipment_orders
    ADD CONSTRAINT shipment_orders_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES public.shipments(id);


--
-- Name: shipments shipments_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shipments
    ADD CONSTRAINT shipments_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: stock_movements stock_movements_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.users(id);


--
-- Name: stock_movements stock_movements_from_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_from_location_id_fkey FOREIGN KEY (from_location_id) REFERENCES public.locations(id);


--
-- Name: stock_movements stock_movements_lot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_lot_id_fkey FOREIGN KEY (lot_id) REFERENCES public.lots(id);


--
-- Name: stock_movements stock_movements_pallet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_pallet_id_fkey FOREIGN KEY (pallet_id) REFERENCES public.pallets(id);


--
-- Name: stock_movements stock_movements_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: stock_movements stock_movements_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: stock_movements stock_movements_to_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_to_location_id_fkey FOREIGN KEY (to_location_id) REFERENCES public.locations(id);


--
-- Name: supplier_products supplier_products_product_id_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT supplier_products_product_id_tenant_id_fkey FOREIGN KEY (product_id, tenant_id) REFERENCES public.products(id, tenant_id);


--
-- Name: supplier_products supplier_products_supplier_id_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT supplier_products_supplier_id_tenant_id_fkey FOREIGN KEY (supplier_id, tenant_id) REFERENCES public.suppliers(id, tenant_id);


--
-- Name: supplier_products supplier_products_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_products
    ADD CONSTRAINT supplier_products_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: suppliers suppliers_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: temperature_readings temperature_readings_shipment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.temperature_readings
    ADD CONSTRAINT temperature_readings_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES public.shipments(id);


--
-- Name: temperature_readings temperature_readings_zone_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.temperature_readings
    ADD CONSTRAINT temperature_readings_zone_id_fkey FOREIGN KEY (zone_id) REFERENCES public.zones(id);


--
-- Name: user_roles user_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id);


--
-- Name: user_roles user_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: zones zones_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zones
    ADD CONSTRAINT zones_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id);


--
-- PostgreSQL database dump complete
--

\unrestrict G7S9XdhSDHSfHHrZmfweIyO5abyLWFhD3JRoUSLDj8Jj2bIcSE46L7eXylBCGGP

