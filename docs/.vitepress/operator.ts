// Who runs ohana.fa-krug.de: the Imprint (§ 5 DDG) and the privacy policy (Art. 13 GDPR) read
// these. A deploy from main refuses to build while a required field is still empty
// (OHANA_SITE_STRICT=1 in .github/workflows/pages.yml), so the site never goes out with an
// incomplete Imprint.
export const operator = {
  /** Full name of the person (or organisation) responsible for the site. */
  name: "",
  /** Postal address that can be served (no PO box). */
  street: "",
  postalCode: "",
  city: "",
  country: "Germany",
  /** An address that is read: § 5 DDG asks for fast electronic contact. */
  email: "",
  /** Optional. */
  phone: "",
}

export const requiredOperatorFields = ["name", "street", "postalCode", "city", "country", "email"] as const

export function missingOperatorFields(): string[] {
  return requiredOperatorFields.filter((key) => !operator[key].trim())
}
