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
                  , coalesce(sum(delivery_fees), 0.0) AS "delivery fees"
                  , coalesce(sum(vendor_sales), 0.0) AS "vendor sales"
                  , coalesce((sum(vendor_sales) * 0.048 + sum(delivery_fees)), 0.0) AS "revenue [sales, delivery fee]"
                  , coalesce(sum(credit_card_processing_fee), 0.0) AS "credit card fees"
                  , coalesce(sum(delivery_cost), 0.0) AS "delivery cost"
                  , count(*) AS "total deliveries"
                  , coalesce((sum(vendor_sales) * 0.0025), 0.0) AS "damages estimate"
                  , SUM(1 - fill_in::INT) AS "deliveries excl fill ins"
          FROM order_sales_fees
          GROUP BY delivery_date, store_id, restaurant_id
      )
      ,

      /*%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%*/
      /* ------------- Subscripution Revenue ----------------- */

      monthly_subscriptions as
      (
          SELECT promo_codes.id
               , orders.store_id
               , orders.restaurant_id
               , date(promo_codes.expiration_date - '31 days'::interval * promo_codes.period) as promo_start_date
               , promo_codes.expiration_date
               --, promo_codes.price / promo_codes.period / 2583.33 AS "Daily Subscription Revenue"
               , promo_codes.price / promo_codes.period / 3100.33 AS "daily subscription revenue"
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
                 , date_sk as "promo active date"
          from monthly_subscriptions t1, dates td
          where td.date_sk between t1.promo_start_date and t1.expiration_date
          order by id, store_id, td.date_sk, restaurant_id
      )
      ,

      subscription_rev as
      (
          SELECT "promo active date"
              , store_id
              , restaurant_id
                  , coalesce(sum("daily subscription revenue"), 0.0) as "daily subscription revenue"
          FROM monthly_subscriptions_daily_view
          GROUP BY "promo active date", store_id, restaurant_id
          ORDER BY "promo active date" DESC
      )
      ,

      sales_fees_daily_subscriptions as
      (
      SELECT coalesce(os.delivery_date, sr."promo active date") as "delivery date"
             , coalesce(os.store_id, sr.store_id) as store_id
             , coalesce(os.restaurant_id, sr.restaurant_id) as restaurant_id
             , coalesce("vendor sales", 0.0) as "vendor sales"
             , coalesce("delivery fees", 0.0) as "delivery fees"
             , coalesce("daily subscription revenue", 0.0) as "daily subscription revenue"
             , coalesce("delivery cost", 0.0) as "delivery cost"
             , coalesce("revenue [sales, delivery fee]", 0.0) as "revenue [sales, delivery fee]"
             , coalesce("credit card fees", 0.0) as "credit card fees"
             , coalesce("damages estimate", 0.0) as "damages estimate"
             , coalesce("total deliveries", 0.0) as "total deliveries"
      FROM order_sales_fee_grouped_by_date os
      FULL OUTER JOIN subscription_rev sr
      ON os.delivery_date = sr."promo active date" and os.restaurant_id = sr.restaurant_id and os.store_id = sr.store_id
      )
      ,

      revenue_fees as
      (
          SELECT "delivery date"
                  , store_id
                  , restaurant_id
                  , coalesce("vendor sales", 0.0) as "vendor sales"
                  , coalesce("delivery fees", 0.0) as "delivery fees"
                  , coalesce("daily subscription revenue", 0.0) as "daily subscription revenue"
                  , coalesce("delivery cost", 0.0) as "delivery cost"
                  , coalesce("revenue [sales, delivery fee]", 0.0) as "revenue [sales, delivery fee]"
                  , coalesce("credit card fees", 0.0) as "credit card fees"
                  , coalesce("damages estimate", 0.0) as "damages estimate"
                  , coalesce("total deliveries", 0.0) as "total deliveries"
          FROM sales_fees_daily_subscriptions
      )

      /*
      select sum("vendor sales" )
             , sum("delivery fees" + "daily subscription revenue") as "total delivery fees"
             , sum("delivery fees" + "daily subscription revenue") / sum("vendor sales") * 100 AS "delivery fee %"
             , sum("credit card fees") as "card charges (2.6% of total transaction)"
             , (sum("delivery fees" + "daily subscription revenue") - sum("delivery cost"))AS "net revenue"
             , (sum("delivery fees" + "daily subscription revenue") - sum("delivery cost"))/ sum("vendor sales")  * 100 AS "deliver fee %"
             , sum("vendor sales") * 0.048 AS "bendor rebate"
             , sum("vendor sales") * 0.048 + sum("delivery fees"+"daily subscription revenue") - sum("delivery cost") AS "total revenue"
             --, sum("Revenue [sales, delivery fee]" + "Daily Subscription Revenue")as "TOTAL Revenue 2"
           , sum("total deliveries") AS "total deliveries"
           , sum("delivery cost") as "delivery cost"
      from revenue_fees
      where "delivery date" between '2018-01-01' and '2018-01-31'
      */

      select *
             , "delivery fees" + "daily subscription revenue" as "total delivery fees"
             , ("delivery fees" + "daily subscription revenue" - "delivery cost") as "net revenue"
             , ("vendor sales") * 0.048 as "vendor rebate"
             , (("vendor sales") * 0.048 + "delivery fees" + "daily subscription revenue" - "delivery cost") AS "total revenue"
             , "vendor sales" + (("vendor sales") * 0.048 + "delivery fees" + "daily subscription revenue" - "delivery cost") as "GMV"
      from revenue_fees
      order by "delivery date" desc, store_id, restaurant_id
       ;;
  }

  measure: count {
    type: count
    drill_fields: [detail*]
  }

  dimension: delivery_date {
    type: date
    label: "delivery date"
    sql: ${TABLE}."delivery date" ;;
  }


  dimension_group: date {
    type: time
    timeframes: [
      raw,
      time,
      date,
      week,
      month,
      quarter,
      year
    ]
    sql:  ${TABLE}."delivery date" ;;
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
    label: "vendor sales"
    sql: ${TABLE}."vendor sales" ;;
  }

  dimension: delivery_fees {
    type: number
    label: "delivery fees"
    sql: ${TABLE}."delivery fees" ;;
  }

  dimension: daily_subscription_revenue {
    type: number
    label: "daily subscription revenue"
    sql: ${TABLE}."daily subscription revenue" ;;
  }

  dimension: delivery_cost {
    type: number
    label: "delivery cost"
    sql: ${TABLE}."delivery cost" ;;
  }

  dimension: revenue_sales_delivery_fee {
    type: number
    label: "revenue [sales, delivery fee]"
    sql: ${TABLE}."revenue [sales, delivery fee]" ;;
  }

  dimension: credit_card_fees {
    type: number
    label: "credit card fees"
    sql: ${TABLE}."credit card fees" ;;
  }

  dimension: damages_estimate {
    type: number
    label: "damages estimate"
    sql: ${TABLE}."damages estimate" ;;
  }

  dimension: total_deliveries {
    type: number
    label: "total deliveries"
    sql: ${TABLE}."total deliveries" ;;
  }

  measure: sum_total_deliveries {
    type: sum
    sql: ${total_deliveries} ;;
  }


  dimension: total_delivery_fees {
    type: number
    label: "total delivery fees"
    sql: ${TABLE}."total delivery fees" ;;
  }

  dimension: net_revenue {
    type: number
    label: "net revenue"
    sql: ${TABLE}."net revenue" ;;
  }

  dimension: vendor_rebate {
    type: number
    label: "vendor rebate"
    sql: ${TABLE}."vendor rebate" ;;
  }

  dimension: total_revenue {
    type: number
    label: "total revenue"
    sql: ${TABLE}."total revenue" ;;
  }

  dimension: gmv {
    type: number
    sql: ${TABLE}.GMV ;;
  }

  measure: sum_gmv  {
    type: sum
    sql: ${gmv} ;;
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
      total_deliveries,
      total_delivery_fees,
      net_revenue,
      vendor_rebate,
      total_revenue,
      gmv
    ]
  }
}
