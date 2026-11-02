// Safari on iOS runs this in the shared page before the share extension opens
// (NSExtensionJavaScriptPreprocessingFile): the extension tells from it whether the page is a
// recipe, and sends what it returns to the server, so the server's assistant reads the page as
// the user sees it (also pages behind a login or built by script). The JSON-LD comes first:
// recipe sites describe their recipe there.

// The schema.org Recipe of the page's JSON-LD: pure functions over the parsed JSON (tested with
// node on plain values).
var OhanaRecipeFinder = {
  // "Recipe", "schema:Recipe", "https://schema.org/Recipe", or an array holding one.
  isRecipeType: function (type) {
    if (Array.isArray(type)) {
      for (var i = 0; i < type.length; i++) if (OhanaRecipeFinder.isRecipeType(type[i])) return true;
      return false;
    }
    if (typeof type !== "string") return false;
    var name = type.trim().toLowerCase().replace(/^https?:\/\/schema\.org\//, "").replace(/^schema:/, "");
    return name === "recipe";
  },

  // The first Recipe object: the value itself, in an array, in @graph or in mainEntity.
  find: function (value, depth) {
    depth = depth || 0;
    if (!value || typeof value !== "object" || depth > 6) return null;
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i++) {
        var found = OhanaRecipeFinder.find(value[i], depth + 1);
        if (found) return found;
      }
      return null;
    }
    if (OhanaRecipeFinder.isRecipeType(value["@type"])) return value;
    return OhanaRecipeFinder.find(value["@graph"], depth + 1) || OhanaRecipeFinder.find(value.mainEntity, depth + 1);
  },

  // The recipe's photo: a string, an ImageObject's url, or the first of an array.
  image: function (image) {
    if (typeof image === "string") return image.trim();
    if (Array.isArray(image)) {
      for (var i = 0; i < image.length; i++) {
        var found = OhanaRecipeFinder.image(image[i]);
        if (found) return found;
      }
      return "";
    }
    if (image && typeof image === "object") {
      return OhanaRecipeFinder.image(image.url || image.contentUrl || "");
    }
    return "";
  },

  name: function (recipe) {
    return typeof recipe.name === "string" ? recipe.name.trim() : "";
  },
};

var OhanaPreprocessor = function () {};

OhanaPreprocessor.prototype = {
  run: function (args) {
    var result = { url: "", title: "" };
    try {
      result.url = document.URL || "";
      result.title = document.title || "";
    } catch (e) {}
    // Whatever the page does, the extension gets at least the address and title.
    try {
      var max = 100000;
      var absolute = function (href) {
        try {
          return new URL(href, document.baseURI).href;
        } catch (e) {
          return href;
        }
      };
      var parts = [];
      var recipe = null;
      var scripts = document.querySelectorAll('script[type="application/ld+json"]');
      for (var i = 0; i < scripts.length; i++) {
        var json = (scripts[i].textContent || "").trim();
        if (!json) continue;
        parts.push(json);
        if (!recipe) {
          try {
            recipe = OhanaRecipeFinder.find(JSON.parse(json));
          } catch (e) {}
        }
      }
      result.recipe = !!recipe;
      if (recipe) {
        result.recipeName = OhanaRecipeFinder.name(recipe);
        var image = OhanaRecipeFinder.image(recipe.image);
        result.recipeImage = image ? absolute(image) : "";
      }

      if (document.body) {
        // innerText lays the page out: on a huge page only the raw text.
        var raw = document.body.textContent || "";
        parts.push(raw.length < 2000000 ? document.body.innerText || "" : raw.slice(0, max));
      }
      var text = parts.join("\n\n");
      result.text = text.length > max ? text.slice(0, max) : text;

      var meta = document.querySelector('meta[property="og:image"], meta[name="og:image"], meta[name="twitter:image"]');
      result.imageUrl = meta && meta.content ? absolute(meta.content) : "";
    } catch (e) {}
    args.completionFunction(result);
  },

  finalize: function (args) {},
};

var ExtensionPreprocessingJS = new OhanaPreprocessor();
