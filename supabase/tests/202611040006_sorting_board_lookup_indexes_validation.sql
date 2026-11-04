begin;
select plan(3);
select has_index('public','sorting_wash_run_customers','sorting_wash_run_customers_source_product_idx','wash run customers indexed by schedule product');
select has_index('public','customer_schedule_trolley_requirements','customer_schedule_trolley_requirements_owner_product_idx','trolley requirements indexed by owner product');
select has_index('public','customer_schedule_trolley_requirement_products','customer_schedule_trolley_requirement_products_product_idx','trolley requirement products indexed by product');
select * from finish();
rollback;
