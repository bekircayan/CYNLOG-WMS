import secrets
from datetime import datetime
from zoneinfo import ZoneInfo

def generate_barcode(connection):
    year = str(datetime.now(ZoneInfo("Europe/Istanbul")).year)

    for _ in range(100):
        barcode = year + f"{secrets.randbelow(100000000):08d}"

        cursor = connection.cursor()
        cursor.execute(
            """
            SELECT 1
            FROM pallets
            WHERE lpn = %s
            UNION ALL
            SELECT 1
            FROM pallet_items
            WHERE barcode = %s
            LIMIT 1
            """,
            (barcode, barcode)
        )

        if cursor.fetchone() is None:
            return barcode

    raise RuntimeError("Benzersiz barkod oluşturulamadı.")
