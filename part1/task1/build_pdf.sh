#!/usr/bin/env bash
# Buduje samowystarczalne PDF-y: pdf/case_study.pdf i pdf/sprawozdanie.pdf (diagramy osadzone w treści).
# Wymaga: docker (obraz pandoc/latex). Diagramy: diagrams/pdf/*.pdf (eksport z draw.io).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build pdf
cat > build/header.tex <<'TEX'
\usepackage{longtable,booktabs,array,lscape}
\renewcommand{\arraystretch}{1.2}
\lstset{breaklines=true,breakatwhitespace=false,basicstyle=\ttfamily\footnotesize,columns=fullflexible,keepspaces=true,
 extendedchars=true,
 literate={ą}{{ą}}1 {ć}{{ć}}1 {ę}{{ę}}1 {ł}{{ł}}1 {ń}{{ń}}1 {ó}{{ó}}1 {ś}{{ś}}1 {ź}{{ź}}1 {ż}{{ż}}1
  {Ą}{{Ą}}1 {Ć}{{Ć}}1 {Ę}{{Ę}}1 {Ł}{{Ł}}1 {Ń}{{Ń}}1 {Ó}{{Ó}}1 {Ś}{{Ś}}1 {Ź}{{Ź}}1 {Ż}{{Ż}}1 {–}{{--}}1 {„}{{"}}1 {”}{{"}}1}
TEX
for doc in case_study sprawozdanie; do
  docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/data" -w /data pandoc/latex \
    "$doc.md" -o "build/$doc.pdf" --pdf-engine=xelatex \
    -V papersize=a4 -V geometry:margin=2cm -V fontsize=10pt \
    -V lang=pl -V colorlinks=true --listings -H build/header.tex
done
cp build/case_study.pdf pdf/case_study.pdf
cp build/sprawozdanie.pdf pdf/sprawozdanie.pdf
echo "Gotowe: pdf/case_study.pdf, pdf/sprawozdanie.pdf"
