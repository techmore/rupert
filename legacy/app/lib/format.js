export function money(cents) {
  if (cents == null) return "—";
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(cents / 100);
}

export function dateTime(value) {
  if (!value) return "—";
  return new Date(value).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export function dateOnly(value) {
  if (!value) return "—";
  return new Date(value).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

export function sumLevels(levels) {
  return (levels || []).reduce((total, level) => total + level.quantity, 0);
}

export function squareQuantity(variant) {
  return sumLevels(
    (variant?.skuLinks || []).flatMap(
      (link) => link?.squareVariation?.levels || [],
    ),
  );
}

export function driftFor(variant) {
  const shopifyQty = sumLevels(variant?.levels);
  const squareQty = squareQuantity(variant);
  return { shopifyQty, squareQty, drift: shopifyQty - squareQty };
}
