# Vločka

Malá aplikace do menu baru: na Macu sněží přes všechno, sníh se drží na oknech, Docku,
ikonách plochy i liště menu, pod okny rostou rampouchy a na Docku si staví sněhuláka.

## Efekty
- Vločky ve třech hloubkách (paralaxa), vítr, intenzita Poprašek / Normální / Vánice.
- Závěje na horních hranách oken (jen viditelné části), na Docku, ikonách a spodním okraji.
- Posunutí okna → sníh sklouzne ve směru pohybu a dopadne na okna pod ním; zavření → spadne vše.
- Rampouchy pod okny, která se ~12 s nehýbou; při pohnutí se ulomí. Rampouchy i pod lištou menu.
- Sněhulák: přikutálí 3 koule, oblékne šálu a mrkev, mává, hází koule na okna a ikony,
  po pár minutách se rozpadne a roztaje. Kliknutím ho rozbíjíš (každý 3. zásah shodí patro),
  někdy se brání.
- Kliknutí sněhem procházejí – myš chytá jen malý panel nad sněhulákem.

## Nastavení (⌘, z menu vločky)
- **Sněžení:** předvolby Poprašek / Normální / Vánice / Kalamita, hustota, max. počet vloček,
  velikost a rychlost vloček, vítr, třpytivé vločky, barva sněhu.
- **Závěje:** kde se sníh drží (okna, Dock, ikony, lišta menu), max. výška na oknech a u spodního
  okraje, rychlost přibývání, tání, rampouchy a jejich délka, tlačítko „Setřást všechen sníh“.
- **Sněhulák:** zapnutí, velikost, pauza mezi sněhuláky, „Postavit hned“, koulovačka a jak často hází.
- **Ostatní:** kurzor rozhání vločky a rychlým tahem shrnuje sníh z oken, ojíněné okraje obrazovky,
  nesněžit přes aplikace na celé obrazovce, 30 / 60 / 120 fps, spouštění po přihlášení,
  obnovení výchozího nastavení.

## Stack a nároky
- Swift 6 (strict concurrency), SwiftUI `MenuBarExtra`, `@Observable`, `SMAppService`.
- Vlastní Metal renderer: 1 instancované volání pro všechny částice + 1 pro trojúhelníky.
  Shadery se kompilují ze zdroje, žádné textury ani assety.
- `CADisplayLink` (max 60 fps, v úsporném režimu 30 fps); když nic nepadá, vykreslování se uspí.
  Při uspání obrazovky / zamčení se vše zastaví.
- Polohy oken z `CGWindowList` (~8×/s, bez oprávnění, nečte obsah). Dock a ikony plochy přes
  Zpřístupnění (volitelné, mimo hlavní vlákno 1×/s).
- Binárka ~270 kB, aplikace ~0,5 MB, ~1 % CPU a ~20 MB paměti při běžném sněžení (M-série).

## Sestavení
```
./build.sh            # build/Vločka.app
./build.sh --install  # zkopíruje do ~/Applications a spustí
```
Ladicí snímek bez okna: `.build/release/Vlocka --snapshot /cesta/snimek.png`.

Pozn.: aplikace je podepsaná ad-hoc, takže po každém přestavění může macOS znovu chtít
povolení Zpřístupnění (Nastavení → Soukromí a zabezpečení → Zpřístupnění).
