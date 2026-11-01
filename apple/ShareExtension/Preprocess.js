// Safari on iOS runs this in the shared page before the share extension opens
// (NSExtensionJavaScriptPreprocessingFile): the extension sends what it returns to the server, so
// the server's assistant reads the page as the user sees it (also pages behind a login or
// built by script). The JSON-LD comes first: recipe sites describe their recipe there.
var OhanaPreprocessor = function () {};

OhanaPreprocessor.prototype = {
  run: function (args) {
    var max = 100000;
    var parts = [];
    var scripts = document.querySelectorAll('script[type="application/ld+json"]');
    for (var i = 0; i < scripts.length; i++) {
      var json = (scripts[i].textContent || "").trim();
      if (json) parts.push(json);
    }
    if (document.body) parts.push(document.body.innerText || "");
    var text = parts.join("\n\n");
    if (text.length > max) text = text.slice(0, max);

    var imageUrl = "";
    var meta = document.querySelector('meta[property="og:image"], meta[name="og:image"], meta[name="twitter:image"]');
    if (meta && meta.content) {
      try {
        imageUrl = new URL(meta.content, document.baseURI).href;
      } catch (e) {
        imageUrl = meta.content;
      }
    }

    args.completionFunction({
      url: document.URL,
      title: document.title || "",
      text: text,
      imageUrl: imageUrl,
    });
  },

  finalize: function (args) {},
};

var ExtensionPreprocessingJS = new OhanaPreprocessor();
