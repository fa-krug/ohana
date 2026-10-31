import DefaultTheme from "vitepress/theme"
import type { Theme } from "vitepress"
import Operator from "./components/Operator.vue"
import "./custom.css"

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component("Operator", Operator)
  },
} satisfies Theme
