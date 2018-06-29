view: orders {
  derived_table: {
    sql: SELECT invoices.id as "invoice_id"
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
       ;;
  }

  measure: count {
    type: count
    drill_fields: [detail*]
  }

  dimension: invoice_id {
    type: string
    primary_key: yes
    sql: ${TABLE}.invoice_id ;;
  }

  dimension: store_id {
    type: number
    sql: ${TABLE}.store_id ;;
  }

  dimension: restaurant_id {
    type: number
    sql: ${TABLE}.restaurant_id ;;
  }

  dimension: fill_in {
    type: string
    sql: ${TABLE}.fill_in ;;
  }

  dimension_group: delivery_date {
    type: time
    timeframes: [raw,date,week,month,year]
    sql: ${TABLE}.delivery_date ;;
  }


  dimension: cart_total {
    type: number
    sql: ${TABLE}.cart_total ;;
  }

  measure: sum_cart_total {
    group_label: "Vendor Sales"
    type: sum
    sql: ${cart_total} ;;
  }


  dimension: alcohol_total {
    type: number
    sql: ${TABLE}.alcohol_total ;;
  }

  measure: sum_alcohol_total {
    group_label: "Vendor Sales"
    type: sum
    sql: ${alcohol_total} ;;
  }

  dimension: base_delivery_fee {
    type: number
    sql: ${TABLE}.base_delivery_fee ;;
  }

  measure: sum_base_delivery_fee {
    type: sum
    sql: ${base_delivery_fee} ;;
  }

  dimension: free_delivery_discount {
    type: number
    sql: ${TABLE}.free_delivery_discount ;;
  }

  dimension: promo_code_discount {
    type: number
    sql: ${TABLE}.promo_code_discount ;;
  }

  dimension: same_day_charge {
    type: number
    sql: ${TABLE}.same_day_charge ;;
  }

  dimension: credit_card_charge {
    type: number
    sql: ${TABLE}.credit_card_charge ;;
  }

  dimension: credit_card_processing_fee {
    type: number
    sql: ${TABLE}.credit_card_processing_fee ;;
  }

  dimension: credit_card_fee_spread {
    type: number
    sql: ${TABLE}.credit_card_fee_spread ;;
  }

  dimension: credits_damage {
    type: number
    sql: ${TABLE}.credits_damage ;;
  }

  dimension: credits_returns {
    type: number
    sql: ${TABLE}.credits_returns ;;
  }

  measure: sum_credits_returns {
    group_label: "Vendor Sales"
    type: sum
    sql: ${credits_returns} ;;
  }

  dimension: general_discount {
    type: number
    sql: ${TABLE}.general_discount ;;
  }

  measure: sum_general_discount {
    type: sum
    sql: ${general_discount} ;;
  }

  dimension: custom {
    type: number
    sql: ${TABLE}.custom ;;
  }

  measure: sum_custom {
    group_label: "Vendor Sales"
    type: sum
    sql: ${custom} ;;
  }

  dimension: total {
    type: number
    sql: ${TABLE}.Total ;;
  }

  measure: sum_vendor_sales {
    type: number
    drill_fields: [detail*]
    sql: ${sum_cart_total} + ${sum_alcohol_total} + ${sum_credits_returns} + ${sum_custom} ;;
  }


  set: detail {
    fields: [
      store_id,
      restaurant_id,
      sum_vendor_sales
    ]
  }
}




#    , (cart_total + alcohol_total + credits_returns + custom) as "vendor_sales"
#               , (base_delivery_fee + free_delivery_discount + promo_code_discount + same_day_charge + credit_card_charge + general_discount) as "delivery_fees"
#               , (credit_card_processing_fee - credits_damage) as "delivery_cost"
