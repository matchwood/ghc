cabal unpack mtl-2.1.2
rm -rf libraries/mtl
mv mtl-2.1.2 libraries/mtl

cabal unpack syb-0.3.7
rm -rf libraries/syb
mv syb-0.3.7 libraries/syb

#cabal unpack jmacro-0.6.2
#rm -rf libraries/jmacro
#mv jmacro-0.6.2 libraries/jmacro

cabal unpack parsec-3.1.3
rm -rf libraries/parsec
mv parsec-3.1.3 libraries/parsec

cabal unpack haskell-src-meta-0.6.0.1
rm -rf libraries/haskell-src-meta
mv haskell-src-meta-0.6.0.1 libraries/haskell-src-meta

cabal unpack haskell-src-exts-1.13.5
rm -rf libraries/haskell-src-exts
mv haskell-src-exts-1.13.5 libraries/haskell-src-exts
happy libraries/haskell-src-exts/src/Language/Haskell/Exts/InternalParser.ly

cabal unpack wl-pprint-text-1.1.0.0
rm -rf libraries/wl-pprint-text
mv wl-pprint-text-1.1.0.0 libraries/wl-pprint-text

cabal unpack text-0.11.2.3
rm -rf libraries/text
mv text-0.11.2.3 libraries/text

cabal unpack unordered-containers-0.2.2.1
rm -rf libraries/unordered-containers
mv unordered-containers-0.2.2.1 libraries/unordered-containers

cabal unpack hashable-1.1.2.5
rm -rf libraries/hashable
mv hashable-1.1.2.5 libraries/hashable

cabal unpack vector-0.10
rm -rf libraries/vector
mv vector-0.10 libraries/vector

cabal unpack primitive-0.5
rm -rf libraries/primitive
mv primitive-0.5 libraries/primitive

cabal unpack aeson-0.6.0.2
rm -rf libraries/aeson
mv aeson-0.6.0.2 libraries/aeson

cabal unpack attoparsec-0.10.2.0
rm -rf libraries/attoparsec
mv attoparsec-0.10.2.0 libraries/attoparsec

cabal unpack blaze-builder-0.3.1.0
rm -rf libraries/blaze-builder
mv blaze-builder-0.3.1.0 libraries/blaze-builder

cabal unpack safe-0.3.3
rm -rf libraries/safe
mv safe-0.3.3 libraries/safe

cabal unpack regex-posix-0.95.2
rm -rf libraries/regex-posix
mv regex-posix-0.95.2 libraries/regex-posix

cabal unpack regex-base-0.93.2
rm -rf libraries/regex-base
mv regex-base-0.93.2 libraries/regex-base

cabal unpack cpphs-1.14
rm -rf libraries/cpphs
mv cpphs-1.14 libraries/cpphs

cabal unpack th-orphans-0.6
rm -rf libraries/th-orphans
mv th-orphans-0.6 libraries/th-orphans

cabal unpack th-lift-0.5.5
rm -rf libraries/th-lift
mv th-lift-0.5.5 libraries/th-lift

cabal unpack dlist-0.5
rm -rf libraries/dlist
mv dlist-0.5 libraries/dlist

cabal unpack parseargs-0.1.3.2
rm -rf libraries/parseargs
mv parseargs-0.1.3.2 libraries/parseargs
