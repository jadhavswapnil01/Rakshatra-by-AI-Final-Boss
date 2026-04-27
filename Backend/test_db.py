import pymysql

try:
    conn = pymysql.connect(
        host="localhost",      # try also "127.0.0.1" if needed
        user="root",
        password="root123",
        database="dtid_db"
    )
    print("✅ Connection successful!")
    conn.close()
except Exception as e:
    print("❌ Connection failed:", e)
