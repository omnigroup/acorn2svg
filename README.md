# acorn2svg

This is a small utility to convert an [`.acorn`
file](http://www.flyingmeat.com/acorn/) into a similar-looking SVG
file so that it can be put on the web, included in larger documents, etc..

This is the result of a couple afternoons' hacking; it is _not_ a
finished piece of software. It will convert many Acorn files
correctly, but does not support everything an Acorn file could
contain. Also, just to be clear, *this is not a Flying Meat Software
product* or related to them in any way; don't blame them for its
flaws! It is released in the hope that it may, with a bit more work,
become useful.

## Building

```shell
git clone ...url... acorn2svg
cd acorn2svg
make
```

## Issues

Many. Obvious deficiencies are marked with `TODO` in the source.  Non-obvious deficiencies are yours to find.

Various Acorn file features are not supported by acorn2svg but they should, for the most part, produce warning messages when encountered.

## License

Acorn2svg is released under the Omni Open Source License
(similar to the MIT or 2-clause BSD licenses),
which is included at the top of each file.

