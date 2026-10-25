# Cost of goods on the item page

The item page (Stock → any item, `/shopify_variants/:id`) shows **Cost of goods** and **Margin per unit**.

## Where the cost comes from

1. **Entered in Rupert** — a cost someone typed on the item page. This always wins.
   The note under the figure says "Entered in Rupert by NAME on DATE".
2. **As entered in C-Trax** — otherwise, the cost on the paired C-Trax item (confirmed pair, or the one item with
   the same SKU). C-Trax is no longer used for new sales, but its costs stay as history and as the fallback.
3. **Unknown** — neither exists. Unknown is never shown as $0.00, and the margin stays Unknown too.

Margin per unit is price minus the cost above, before tax: an estimate, not accounting profit.

## How to enter or change a cost

People with inventory write permission (`inventory.write`, e.g. admins and inventory employees):

1. Open the item (search its name or SKU, or click it on Inventory / Stock comparison).
2. Under the Price / Cost / Margin boxes, click **Add cost** (or **Edit cost** when one is already entered).
3. Type the cost per unit, e.g. `6.50`, and click **Save**.

To go back to the C-Trax cost, open **Edit cost** and click **Remove** (or empty the box and Save).

Readers see the cost but not the form. The cost is stored in Rupert only (`item_costs`, one per Shopify variant
per tenant); nothing is sent to Shopify, Square or C-Trax. Every save and removal is in the activity log
(`item_cost_set`, `item_cost_removed`) with the old and new amount.

Not yet: a bulk CSV import of SKU,cost. Enter costs one item at a time for now.
