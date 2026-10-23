// GENERIC TEST — documents/fixed-generic-raw-rule.typ
// The corrected pattern: same styling (small monospace, fill, inset), but the
// raw ELEMENT (`it`) is kept so Typst's built-in highlighting survives.
// Expected: syntax highlighting present, same overall layout.
#set page(width: 500pt, height: auto, margin: 12pt)

#show raw.where(block: true): it => {
  set text(font: ("Menlo", "Courier New", "DejaVu Sans Mono"), size: 8pt)
  set par(justify: false, leading: 0.5em)
  block(width: 100%, breakable: true, fill: luma(245), inset: 8pt)[#it]
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
