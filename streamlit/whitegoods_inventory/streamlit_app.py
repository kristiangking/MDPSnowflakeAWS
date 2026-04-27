import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.set_page_config(layout="wide")
st.title("🏭 Whitegoods Inventory Dashboard")

# ── Sidebar filters ────────────────────────────────────────────
st.sidebar.header("Filters")

locations = session.sql(
    "SELECT DISTINCT location_name FROM ANALYTICS.marts.mart_inventory_summary ORDER BY 1"
).to_pandas()["LOCATION_NAME"].tolist()

categories = session.sql(
    "SELECT DISTINCT category FROM ANALYTICS.marts.mart_inventory_summary ORDER BY 1"
).to_pandas()["CATEGORY"].tolist()

selected_locations = st.sidebar.multiselect("Location", locations, default=locations)
selected_categories = st.sidebar.multiselect("Category", categories, default=categories)

loc_filter = "', '".join(selected_locations)
cat_filter = "', '".join(selected_categories)

# ── Tab layout ─────────────────────────────────────────────────
tab1, tab2, tab3, tab4 = st.tabs([
    "📦 Inventory Overview",
    "🛒 Purchase Orders",
    "📥 Receiving Activity",
    "📈 Stock Movement"
])

# ══════════════════════════════════════════════════════════════
# TAB 1 — Inventory Overview
# ══════════════════════════════════════════════════════════════
with tab1:
    st.subheader("Stock on Hand")

    inv = session.sql(f"""
        SELECT
            product_name,
            category,
            location_name,
            qty_on_hand,
            reorder_point,
            stock_value_cost,
            is_below_reorder_point
        FROM ANALYTICS.marts.mart_inventory_summary
        WHERE location_name IN ('{loc_filter}')
          AND category IN ('{cat_filter}')
        ORDER BY category, product_name
    """).to_pandas()

    # KPI row
    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Total SKU/Locations", len(inv))
    col2.metric("Total Units", f"{inv['QTY_ON_HAND'].sum():,}")
    col3.metric("Stock Value (Cost)", f"${inv['STOCK_VALUE_COST'].sum():,.0f}")
    col4.metric("Below Reorder Point", int(inv['IS_BELOW_REORDER_POINT'].sum()))

    st.divider()

    # Stock by category bar chart
    st.subheader("Units by Category")
    cat_summary = inv.groupby("CATEGORY")["QTY_ON_HAND"].sum().reset_index()
    st.bar_chart(cat_summary.set_index("CATEGORY"))

    st.divider()

    # Reorder alerts
    st.subheader("⚠️ Reorder Alerts")
    alerts = inv[inv["IS_BELOW_REORDER_POINT"] == True][[
        "PRODUCT_NAME", "CATEGORY", "LOCATION_NAME", "QTY_ON_HAND", "REORDER_POINT"
    ]]
    if alerts.empty:
        st.success("All products are above reorder point.")
    else:
        st.dataframe(alerts, use_container_width=True)

# ══════════════════════════════════════════════════════════════
# TAB 2 — Purchase Orders
# ══════════════════════════════════════════════════════════════
with tab2:
    st.subheader("Purchase Orders")
    st.info("Coming soon — will show open PO status, supplier lead times, and delivery performance.")

# ══════════════════════════════════════════════════════════════
# TAB 3 — Receiving Activity
# ══════════════════════════════════════════════════════════════
with tab3:
    st.subheader("Receiving Activity")
    st.info("Coming soon — will show recent goods receipts and variance vs ordered qty.")

# ══════════════════════════════════════════════════════════════
# TAB 4 — Stock Movement
# ══════════════════════════════════════════════════════════════
with tab4:
    st.subheader("Stock Movement")
    st.info("Coming soon — will show inventory event history and net qty changes over time.")
