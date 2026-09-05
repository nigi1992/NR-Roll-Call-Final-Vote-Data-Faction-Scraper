#!/usr/bin/env python3
"""
export_xlsx.py — Write .xlsx copies of the output CSVs with the ID columns
(gesch_nr, anr, entwurf_nr, parl_date, referendum_date) explicitly formatted as
TEXT, so Excel/Numbers don't re-strip the leading/trailing zeros of gesch_nr on
open. (The CSVs are already correct, this is purely so the spreadsheet apps
display them faithfully.)
"""
import os
import csv
import glob

import openpyxl
from openpyxl.utils import get_column_letter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "output")
TEXT_COLS = {"gesch_nr", "anr", "entwurf_nr", "parl_date", "referendum_date",
             "vote_date", "bill_number", "vote_ref"}


def export(csv_path):
    rows = list(csv.reader(open(csv_path, encoding="utf-8-sig")))
    if not rows:
        return
    header = rows[0]
    text_idx = {i for i, h in enumerate(header) if h in TEXT_COLS}
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.append(header)
    for r in rows[1:]:
        ws.append(r)
    # forcing the ID columns to text so zeros are preserved on display
    for i in text_idx:
        col = get_column_letter(i + 1)
        for cell in ws[col]:
            cell.number_format = "@"
    xlsx = csv_path[:-4] + ".xlsx"
    wb.save(xlsx)
    print(f"wrote {os.path.basename(xlsx)}  ({len(rows)-1} rows)")


def main():
    for f in sorted(glob.glob(os.path.join(OUT, "csv", "*.csv"))):
        export(f)


if __name__ == "__main__":
    main()
