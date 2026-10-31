<script setup lang="ts">
// The operator's contact block for the Imprint and the privacy policy (docs/.vitepress/operator.ts).
import { operator } from "../../operator"

const field = (value: string, label: string) => value.trim() || `[${label}]`
const missing = (value: string) => !value.trim()
</script>

<template>
  <p class="operator">
    <span :class="{ 'operator-missing': missing(operator.name) }">{{ field(operator.name, "Name") }}</span><br />
    <span :class="{ 'operator-missing': missing(operator.street) }">{{ field(operator.street, "Street and number") }}</span><br />
    <span :class="{ 'operator-missing': missing(operator.postalCode) || missing(operator.city) }">
      {{ field(operator.postalCode, "Postal code") }} {{ field(operator.city, "City") }}
    </span><br />
    <span>{{ field(operator.country, "Country") }}</span>
  </p>
  <p class="operator">
    E-Mail:
    <a v-if="!missing(operator.email)" :href="`mailto:${operator.email}`">{{ operator.email }}</a>
    <span v-else class="operator-missing">[E-mail]</span>
    <template v-if="operator.phone.trim()"><br />Telefon / Phone: {{ operator.phone }}</template>
  </p>
</template>
