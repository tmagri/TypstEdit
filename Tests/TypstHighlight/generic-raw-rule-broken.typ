// GENERIC TEST — documents/common-generic-raw-rule.typ
// Reproduces the "custom raw show rule that flattens highlighting" pattern:
// a block-level raw show rule that reconstructs code from `it.text`.
// Expected: NO syntax highlighting (this is the defect pattern).
#set page(width: 500pt, height: auto, margin: 12pt)

#show raw.where(block: true): it => {
  set text(font: ("Menlo", "Courier New", "DejaVu Sans Mono"), size: 8pt)
  set par(justify: false, leading: 0.5em)
  block(width: 100%, breakable: true, fill: luma(245), inset: 8pt)[
    #for line in it.text.split("\n") {
      text(line)
      linebreak()
    }
  ]
}

= Sample section

```csharp
public class Widget {
    public static void Main() {
        string name = "World";
        Console.WriteLine($"Hello, {name}!");
    }
}
```

```json
{
  "name": "test",
  "count": 42,
  "active": true
}
```
