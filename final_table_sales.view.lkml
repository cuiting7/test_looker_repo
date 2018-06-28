view: final_table_sales {
  derived_table: {
    sql: with

      order_breakdown as
      (
          SELECT invoices.id as "invoice_id"
                 , orders.store_id AS "store_id"
                 , orders.restaurant_id as "restaurant_id"
                 , orders.fill_in AS "fill_in"
                 , orders.delivery_date AS "delivery_date"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 0 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "cart_total"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 11 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "alcohol_total"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 1 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "base_delivery_fee"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 2 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "free_delivery_discount"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 3 AND invoice_items.price < 0 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "promo_code_discount"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 4 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "same_day_charge"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 5 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "credit_card_charge"
                 , 0.01 * 0.026 * sum(CASE WHEN invoices.payment_method = 0 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "credit_card_processing_fee"
                 , 0.01 * (sum(CASE WHEN invoice_items.item_type = 5 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) - 0.026 * SUM(CASE WHEN invoices.payment_method = 0 THEN invoice_items.price * invoice_items.quantity ELSE 0 END)) AS "credit_card_fee_spread"
                 , 0.01 * sum(CASE WHEN (invoice_items.item_type = 12) OR (invoice_items.item_type = 6 AND invoice_items.description like '%Damage%') THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "credits_damage"
                 , 0.01 * sum(CASE WHEN (invoice_items.item_type = 13) OR (invoice_items.item_type = 6 AND invoice_items.description like '%Return%') THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "credits_returns"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 7 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "general_discount"
                 , 0.01 * sum(CASE WHEN invoice_items.item_type = 9 THEN invoice_items.price * invoice_items.quantity ELSE 0 END) AS "custom"
                 , 0.01 * invoices.total AS "Total"
          FROM invoices
          JOIN orders ON invoices.order_id = orders.id
          JOIN invoice_items ON invoices.id = invoice_items.invoice_id
          WHERE orders.status IN (4, 8)
          AND invoice_items.item_type <> 10
          GROUP BY invoices.id
                   , orders.store_id
                   , orders.restaurant_id
                   , orders.fill_in
                   , orders.delivery_date
                   , invoices.total
          HAVING invoices.total > 0
      )
      ,

      order_sales_fees as
      (
          SELECT *
              , (cart_total + alcohol_total + credits_returns + custom) as "vendor_sales"
              , (base_delivery_fee + free_delivery_discount + promo_code_discount + same_day_charge + credit_card_charge + general_discount) as "delivery_fees"
              , (credit_card_processing_fee - credits_damage) as "delivery_cost"
          FROM order_breakdown
      )
      ,

      order_sales_fee_grouped_by_date as
      (
          SELECT delivery_date
              , store_id
              , restaurant_id
                  , coalesce(sum(delivery_fees), 0.0) AS "DELIVERY FEES"
                  , coalesce(sum(vendor_sales), 0.0) AS "Vendor Sales"
                  , coalesce((sum(vendor_sales) * 0.048 + sum(delivery_fees)), 0.0) AS "Revenue [sales, delivery fee]"
                  , coalesce(sum(credit_card_processing_fee), 0.0) AS "CREDIT CARD FEES"
                  , coalesce(sum(delivery_cost), 0.0) AS "DELIVERY COST"
                  , count(*) AS "TOTAL DELIVERIES"
                  , coalesce((sum(vendor_sales) * 0.0025), 0.0) AS "DAMAGES ESTIMATE"
                  , SUM(1 - fill_in::INT) AS "DELIVERIES EXCL FILL INS"
          FROM order_sales_fees
          GROUP BY delivery_date, store_id, restaurant_id
      )
      ,

      monthly_subscriptions as
      (
          SELECT promo_codes.id
               , orders.store_id
               , orders.restaurant_id
               , date(promo_codes.expiration_date - '31 days'::interval * promo_codes.period) as promo_start_date
               , promo_codes.expiration_date
               --, promo_codes.price / promo_codes.period / 2583.33 AS "Daily Subscription Revenue"
               , promo_codes.price / promo_codes.period / 3100.33 AS "Daily Subscription Revenue"
          FROM promo_codes
          JOIN orders ON promo_codes.order_id = orders.id
          WHERE orders.status > 0
          AND promo_codes.expiration_date IS NOT NULL
          AND promo_codes.type IN ('MonthlySubscription', 'CappedMonthlySubscription')
      )
      ,

      dates as
      (
        select now()::date - generate_series(0, 3700) as date_sk
      )
      ,


      monthly_subscriptions_daily_view as
      (
          select t1.*
                 , date_sk as "Promo Active Date"
          from monthly_subscriptions t1, dates td
          where td.date_sk between t1.promo_start_date and t1.expiration_date
          order by id, store_id, td.date_sk, restaurant_id
      )
      ,

      subscription_rev as
      (
          SELECT "Promo Active Date"
              , store_id
              , restaurant_id
                  , coalesce(sum("Daily Subscription Revenue"), 0.0) as "Daily Subscription Revenue"
          FROM monthly_subscriptions_daily_view
          GROUP BY "Promo Active Date", store_id, restaurant_id
          ORDER BY "Promo Active Date" DESC
      )
      ,

      sales_fees_daily_subscriptions as
      (
      SELECT coalesce(os.delivery_date, sr."Promo Active Date") as "Delivery Date"
             , coalesce(os.store_id, sr.store_id) as store_id
             , coalesce(os.restaurant_id, sr.restaurant_id) as restaurant_id
             , coalesce("Vendor Sales", 0.0) as "Vendor Sales"
             , coalesce("DELIVERY FEES", 0.0) as "DELIVERY FEES"
             , coalesce("Daily Subscription Revenue", 0.0) as "Daily Subscription Revenue"
             , coalesce("DELIVERY COST", 0.0) as "DELIVERY COST"
             , coalesce("Revenue [sales, delivery fee]", 0.0) as "Revenue [sales, delivery fee]"
             , coalesce("CREDIT CARD FEES", 0.0) as "CREDIT CARD FEES"
             , coalesce("DAMAGES ESTIMATE", 0.0) as "DAMAGES ESTIMATE"
             , coalesce("TOTAL DELIVERIES", 0.0) as "TOTAL DELIVERIES"
      FROM order_sales_fee_grouped_by_date os
      FULL OUTER JOIN subscription_rev sr
      ON os.delivery_date = sr."Promo Active Date" and os.restaurant_id = sr.restaurant_id and os.store_id = sr.store_id
      )
      ,

      revenue_fees as
      (
          SELECT "Delivery Date"
                  , store_id
                  , restaurant_id
                  , coalesce("Vendor Sales", 0.0) as "Vendor Sales"
                  , coalesce("DELIVERY FEES", 0.0) as "DELIVERY FEES"
                  , coalesce("Daily Subscription Revenue", 0.0) as "Daily Subscription Revenue"
                  , coalesce("DELIVERY COST", 0.0) as "DELIVERY COST"
                  , coalesce("Revenue [sales, delivery fee]", 0.0) as "Revenue [sales, delivery fee]"
                  , coalesce("CREDIT CARD FEES", 0.0) as "CREDIT CARD FEES"
                  , coalesce("DAMAGES ESTIMATE", 0.0) as "DAMAGES ESTIMATE"
                  , coalesce("TOTAL DELIVERIES", 0.0) as "TOTAL DELIVERIES"
          FROM sales_fees_daily_subscriptions
      )

      /*
      select sum("vendor sales") as "vendor sales"
             , sum("DELIVERY FEES" + "Daily Subscription Revenue") as "TOTAL DELIVERY FEES"
             , sum("DELIVERY FEES" + "Daily Subscription Revenue") / sum("vendor sales") * 100 AS "DELIVERY FEE %"
             , sum("CREDIT CARD FEES") as "Card charges (2.6% of total transaction)"
             , (sum("DELIVERY FEES" + "Daily Subscription Revenue") - sum("DELIVERY COST"))AS "Net Revenue"
             , (sum("DELIVERY FEES" + "Daily Subscription Revenue") - sum("DELIVERY COST"))/ sum("vendor sales")  * 100 AS "Deliver Fee %"
             , sum("vendor sales") * 0.048 AS "vendor rebate"
             , sum("vendor sales") * 0.048 + sum("DELIVERY FEES"+ "Daily Subscription Revenue") - sum("DELIVERY COST") AS "total revenue"
             --, sum("Revenue [sales, delivery fee]" + "Daily Subscription Revenue")as "TOTAL Revenue 2"
           , sum("TOTAL DELIVERIES") AS "TOTAL_DELIVERIES"
           , sum("DELIVERY COST") as "DELIVERY COST"

      from revenue_fees
      where "Delivery Date" between '2018-01-01' and '2018-01-31'
      ;
      */

      select * from revenue_fees
      order by "Delivery Date" desc, store_id, restaurant_id
       ;;
  }

  measure: count {
    type: count
    drill_fields: [detail*]
  }

  dimension: delivery_date {
    type: date
    label: "Delivery Date"
    sql: ${TABLE}."Delivery Date" ;;
  }

  dimension: store_id {
    type: number
    sql: ${TABLE}.store_id ;;
  }

  dimension: restaurant_id {
    type: number
    sql: ${TABLE}.restaurant_id ;;
  }

  dimension: vendor_sales {
    type: number
    label: "Vendor Sales"
    sql: ${TABLE}."Vendor Sales" ;;
  }

  dimension: delivery_fees {
    type: number
    label: "DELIVERY FEES"
    sql: ${TABLE}."DELIVERY FEES" ;;
  }

  dimension: daily_subscription_revenue {
    type: number
    label: "Daily Subscription Revenue"
    sql: ${TABLE}."Daily Subscription Revenue" ;;
  }

  dimension: delivery_cost {
    type: number
    label: "DELIVERY COST"
    sql: ${TABLE}."DELIVERY COST" ;;
  }

  dimension: revenue_sales_delivery_fee {
    type: number
    label: "Revenue [sales, delivery fee]"
    sql: ${TABLE}."Revenue [sales, delivery fee]" ;;
  }

  dimension: credit_card_fees {
    type: number
    label: "CREDIT CARD FEES"
    sql: ${TABLE}."CREDIT CARD FEES" ;;
  }

  dimension: damages_estimate {
    type: number
    label: "DAMAGES ESTIMATE"
    sql: ${TABLE}."DAMAGES ESTIMATE" ;;
  }

  dimension: total_deliveries {
    type: number
    label: "TOTAL DELIVERIES"
    sql: ${TABLE}."TOTAL DELIVERIES" ;;
  }

  set: detail {
    fields: [
      delivery_date,
      store_id,
      restaurant_id,
      vendor_sales,
      delivery_fees,
      daily_subscription_revenue,
      delivery_cost,
      revenue_sales_delivery_fee,
      credit_card_fees,
      damages_estimate,
      total_deliveries
    ]
  }
}
