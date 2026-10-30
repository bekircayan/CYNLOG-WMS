from barcode_service import generate_barcode
import os, hashlib, hmac, secrets, re, io
from datetime import date
from decimal import Decimal
from contextlib import asynccontextmanager
from pathlib import Path
from openpyxl import load_workbook
import psycopg
from psycopg.rows import dict_row
from fastapi import FastAPI, HTTPException, Request, Response, Depends, UploadFile, File, Form
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator
from itsdangerous import URLSafeTimedSerializer, BadSignature, SignatureExpired

DB=os.environ['DATABASE_URL']; SECRET=os.environ['SECRET_KEY']
signer=URLSafeTimedSerializer(SECRET, salt='cynlog-wms-auth')
def db(): return psycopg.connect(DB, row_factory=dict_row)
def hashed(password):
    salt=secrets.token_bytes(16)
    return 'scrypt$'+salt.hex()+'$'+hashlib.scrypt(password.encode(),salt=salt,n=2**14,r=8,p=1).hex()
def verify(password, encoded):
    try:
        _,salt,expected=encoded.split('$')
        actual=hashlib.scrypt(password.encode(),salt=bytes.fromhex(salt),n=2**14,r=8,p=1)
        return hmac.compare_digest(actual,bytes.fromhex(expected))
    except (ValueError,TypeError): return False
@asynccontextmanager
async def lifespan(app):
    with db() as c:
        with c.transaction():
            c.execute("INSERT INTO roles(code) VALUES('ADMIN'),('RECEIVING'),('PUTAWAY'),('VIEWER') ON CONFLICT DO NOTHING")
            email=os.environ['ADMIN_EMAIL'].strip().lower()
            if not c.execute('SELECT 1 FROM users WHERE email=%s',(email,)).fetchone():
                u=c.execute('INSERT INTO users(email,password_hash,full_name) VALUES(%s,%s,%s) RETURNING id',(email,hashed(os.environ['ADMIN_PASSWORD']),'Sistem Yöneticisi')).fetchone()
                c.execute("INSERT INTO user_roles(user_id,role_id) SELECT %s,id FROM roles WHERE code='ADMIN'",(u['id'],))
    yield
app=FastAPI(title='CYNLOG WMS API', lifespan=lifespan)
app.mount('/static',StaticFiles(directory='static'),name='static')
@app.get('/')
def home(): return FileResponse('static/index.html')
def actor(req:Request):
    token=req.cookies.get('cynlog_session')
    try: uid=signer.loads(token,max_age=8*3600) if token else None
    except (BadSignature,SignatureExpired): uid=None
    if not uid: raise HTTPException(401,'Oturum açmanız gerekiyor')
    with db() as c:
        u=c.execute('SELECT id,email,full_name FROM users WHERE id=%s AND active=true',(uid,)).fetchone()
        if not u: raise HTTPException(401,'Hesap pasif')
        u['roles']=[r['code'] for r in c.execute('SELECT r.code FROM roles r JOIN user_roles ur ON ur.role_id=r.id WHERE ur.user_id=%s',(uid,)).fetchall()]
        return u
def require(*roles):
    def check(u=Depends(actor)):
        if 'ADMIN' not in u['roles'] and not set(roles).intersection(u['roles']): raise HTTPException(403,'Bu işlem için yetkiniz yok')
        return u
    return check
class Login(BaseModel): email:str; password:str
@app.post('/api/login')
def login(data:Login,response:Response):
    with db() as c: u=c.execute('SELECT * FROM users WHERE email=%s AND active=true',(data.email.lower().strip(),)).fetchone()
    if not u or not verify(data.password,u['password_hash']): raise HTTPException(401,'E-posta veya parola hatalı')
    response.set_cookie('cynlog_session',signer.dumps(str(u['id'])),httponly=True,samesite='strict',secure=os.getenv('COOKIE_SECURE','false').lower()=='true',max_age=28800)
    return {'ok':True}
@app.post('/api/logout')
def logout(response:Response): response.delete_cookie('cynlog_session'); return {'ok':True}
@app.get('/api/me')
def me(u=Depends(actor)): return u
class Staff(BaseModel): email:str; full_name:str; password:str=Field(min_length=12); role:str
@app.post('/api/staff')
def add_staff(data:Staff,u=Depends(require('ADMIN'))):
    if data.role not in ('ADMIN','RECEIVING','PUTAWAY','VIEWER'): raise HTTPException(422,'Geçersiz rol')
    with db() as c:
        with c.transaction():
            try:
                user=c.execute('INSERT INTO users(email,full_name,password_hash) VALUES(%s,%s,%s) RETURNING id',(data.email.lower(),data.full_name,hashed(data.password))).fetchone()
                c.execute('INSERT INTO user_roles SELECT %s,id FROM roles WHERE code=%s',(user['id'],data.role))
            except psycopg.errors.UniqueViolation: raise HTTPException(409,'Bu e-posta zaten kayıtlı')
    return {'ok':True}
@app.get('/api/catalog')
def catalog(u=Depends(actor)):
    with db() as c:
        return {key:c.execute(sql).fetchall() for key,sql in {
            'tenants':'SELECT id,name,customer_code,legal_name,tax_number,phone,email,contact_person,regimes FROM tenants WHERE active=true ORDER BY name',
            'suppliers':'SELECT id,tenant_id,code,name FROM suppliers WHERE active=true ORDER BY name',
            'supplier_products':'SELECT supplier_id,product_id FROM supplier_products',
            'warehouses':'SELECT id,name,code FROM warehouses ORDER BY code',
            'products':'SELECT id,tenant_id,sku,name,barcode,regime,base_uom,units_per_case,case_weight_kg,cases_per_pallet,net_weight_kg,gross_weight_kg,expiry_warning_days FROM products WHERE active ORDER BY name',
            'locations':"SELECT l.id,l.code,l.capacity_pallets,z.regime,z.warehouse_id,z.code AS zone_code FROM locations l JOIN zones z ON z.id=l.zone_id WHERE l.active ORDER BY l.code",
            'pallets':"SELECT p.id,p.lpn,p.tenant_id,p.warehouse_id,p.location_id,p.status,l.code AS location_code FROM pallets p LEFT JOIN locations l ON l.id=p.location_id ORDER BY p.created_at DESC LIMIT 200"
        }.items()}
class Tenant(BaseModel):
    customer_code: str = Field(min_length=2,max_length=30)
    legal_name: str = Field(min_length=2,max_length=250)
    tax_number: str = Field(pattern=r'^(?:[0-9]{10}|[0-9]{11})$')
    tax_office: str | None = None
    contact_person: str | None = None
    phone: str | None = None
    email: str | None = None
    address: str | None = None
    regimes: list[str] = Field(min_length=1)
    @field_validator('regimes')
    @classmethod
    def valid_regimes(cls,v):
        allowed={'FROZEN','CHILLED','AMBIENT','SHOCK'}
        if len(v)!=len(set(v)) or not set(v).issubset(allowed): raise ValueError('Geçersiz veya tekrar eden sıcaklık rejimi')
        return v
    @field_validator('email')
    @classmethod
    def valid_email(cls,v):
        if v and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',v.strip()): raise ValueError('E-posta biçimi geçersiz')
        return v.strip().lower() if v else None

@app.post('/api/tenants')
def tenant(data:Tenant,u=Depends(require('RECEIVING'))):
    with db() as c:
      with c.transaction():
        c.execute('SELECT pg_advisory_xact_lock(2525)')
        n=c.execute('SELECT count(*) AS n FROM tenants WHERE active=true').fetchone()['n']
        if n>=25: raise HTTPException(409,'En fazla 25 aktif müşteri tanımlanabilir')
        if c.execute('SELECT 1 FROM tenants WHERE lower(customer_code)=lower(%s)',(data.customer_code.strip(),)).fetchone(): raise HTTPException(409,'Müşteri kodu zaten kayıtlı')
        if c.execute('SELECT 1 FROM tenants WHERE tax_number=%s',(data.tax_number,)).fetchone(): raise HTTPException(409,'Vergi numarası zaten kayıtlı')
        if c.execute('SELECT 1 FROM tenants WHERE lower(trim(name))=lower(%s) AND active=true',(data.legal_name.strip(),)).fetchone(): raise HTTPException(409,'Bu ticari unvanda aktif müşteri zaten var')
        result=c.execute("""INSERT INTO tenants(name,customer_code,legal_name,tax_number,tax_office,contact_person,phone,email,address,regimes)
            VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id,name,customer_code,legal_name,tax_number,regimes""",
            (data.legal_name.strip(),data.customer_code.strip().upper(),data.legal_name.strip(),data.tax_number,data.tax_office,data.contact_person,data.phone,data.email,data.address,data.regimes)).fetchone()
        c.execute('INSERT INTO master_data_audit(actor_id,entity_type,entity_id,action) VALUES(%s,%s,%s,%s)',(u['id'],'CUSTOMER',result['id'],'CREATE'))
        return result
class Supplier(BaseModel): tenant_id:str; code:str=Field(min_length=1); name:str=Field(min_length=2)
@app.post('/api/suppliers')
def add_supplier(d:Supplier,u=Depends(require('RECEIVING'))):
    with db() as c:
      try:
        with c.transaction():
          if not c.execute('SELECT 1 FROM tenants WHERE id=%s AND active=true',(d.tenant_id,)).fetchone(): raise HTTPException(422,'Aktif müşteri bulunamadı')
          if c.execute('SELECT 1 FROM suppliers WHERE tenant_id=%s AND lower(trim(name))=lower(%s) AND active=true',(d.tenant_id,d.name.strip())).fetchone(): raise HTTPException(409,'Bu müşteride aynı isimde tedarikçi var')
          result=c.execute('INSERT INTO suppliers(tenant_id,code,name) VALUES(%s,%s,%s) RETURNING id,tenant_id,code,name',(d.tenant_id,d.code.strip(),d.name.strip())).fetchone()
          c.execute('INSERT INTO master_data_audit(actor_id,entity_type,entity_id,action) VALUES(%s,%s,%s,%s)',(u['id'],'SUPPLIER',result['id'],'CREATE'))
          return result
      except psycopg.errors.UniqueViolation: raise HTTPException(409,'Bu müşteri için tedarikçi kodu zaten kayıtlı')
class SupplierProduct(BaseModel): tenant_id:str; supplier_id:str; product_id:str
@app.post('/api/supplier-products')
def assign_supplier_product(d:SupplierProduct,u=Depends(require('ADMIN'))):
    with db() as c:
      try:
        with c.transaction():
          c.execute('INSERT INTO supplier_products(tenant_id,supplier_id,product_id) VALUES(%s,%s,%s)',(d.tenant_id,d.supplier_id,d.product_id))
      except psycopg.errors.UniqueViolation: raise HTTPException(409,'Ürün bu tedarikçiye zaten bağlı')
      except psycopg.errors.ForeignKeyViolation: raise HTTPException(422,'Müşteri, tedarikçi ve ürün aynı müşteriye ait olmalıdır')
    return {'ok':True}
class Warehouse(BaseModel): code:str; name:str
@app.post('/api/warehouses')
def warehouse(data:Warehouse,u=Depends(require('ADMIN'))):
    with db() as c: return c.execute('INSERT INTO warehouses(code,name) VALUES(%s,%s) RETURNING id,code,name',(data.code,data.name)).fetchone()
class Zone(BaseModel): warehouse_id:str; code:str; regime:str
@app.post('/api/zones')
def zone(data:Zone,u=Depends(require('ADMIN'))):
    if data.regime not in ('FROZEN','CHILLED','AMBIENT','SHOCK','QUARANTINE'): raise HTTPException(422,'Geçersiz rejim')
    with db() as c: return c.execute('INSERT INTO zones(warehouse_id,code,regime) VALUES(%s,%s,%s) RETURNING id,code',(data.warehouse_id,data.code,data.regime)).fetchone()
class Location(BaseModel): zone_id:str; code:str; capacity_pallets:int=Field(default=1,ge=1)
@app.post('/api/locations')
def location(data:Location,u=Depends(require('ADMIN'))):
    with db() as c: return c.execute('INSERT INTO locations(zone_id,code,capacity_pallets) VALUES(%s,%s,%s) RETURNING id,code',(data.zone_id,data.code,data.capacity_pallets)).fetchone()
class Product(BaseModel): tenant_id:str; sku:str; name:str; barcode:str|None=None; base_uom:str='ADET'; regime:str
@app.post('/api/products')
def product(data:Product,u=Depends(require('ADMIN'))):
    if data.regime not in ('FROZEN','CHILLED','AMBIENT','SHOCK'): raise HTTPException(422,'Geçersiz rejim')
    with db() as c: return c.execute('INSERT INTO products(tenant_id,sku,name,barcode,base_uom,regime) VALUES(%s,%s,%s,%s,%s,%s) RETURNING id,sku,name',(data.tenant_id,data.sku,data.name,data.barcode,data.base_uom,data.regime)).fetchone()

# Product catalog operations. A single database transaction is used for bulk imports.
ALLOWED_REGIMES={'FROZEN','CHILLED','AMBIENT','SHOCK'}
ALLOWED_UNITS={'ADET','KOLİ','KG'}
class ProductCreate(BaseModel):
    tenant_id:str
    sku:str=Field(min_length=1,max_length=80)
    name:str=Field(min_length=2,max_length=250)
    barcode:str|None=None
    base_uom:str='ADET'
    regime:str
    supplier_ids:list[str]=Field(default_factory=list)
    units_per_case:int|None=Field(default=None,ge=1)
    case_weight_kg:float|None=Field(default=None,gt=0)
    cases_per_pallet:int|None=Field(default=None,ge=1)
    net_weight_kg:float|None=Field(default=None,gt=0)
    gross_weight_kg:float|None=Field(default=None,gt=0)
    expiry_warning_days:int=Field(default=30,ge=0,le=3650)


@app.post('/api/product-cards')
def create_product_card(d:ProductCreate,u=Depends(require('ADMIN'))):
    if d.regime not in ALLOWED_REGIMES or d.base_uom not in ALLOWED_UNITS: raise HTTPException(422,'Rejim veya birim geçersiz')
    sku=d.sku.strip(); name=d.name.strip(); barcode=(d.barcode or '').strip() or None
    if not sku or not name: raise HTTPException(422,'SKU ve ürün adı zorunlu')
    if d.net_weight_kg is not None and d.gross_weight_kg is not None and d.gross_weight_kg<d.net_weight_kg: raise HTTPException(422,'Brüt ağırlık net ağırlıktan küçük olamaz')
    if len(d.supplier_ids)!=len(set(d.supplier_ids)): raise HTTPException(422,'Tekrarlanan tedarikçi')
    with db() as c:
      try:
        with c.transaction():
          tenant=c.execute('SELECT regimes FROM tenants WHERE id=%s AND active=true',(d.tenant_id,)).fetchone()
          if not tenant: raise HTTPException(422,'Müşteri bulunamadı')
          if d.regime not in tenant['regimes']: raise HTTPException(422,'Ürün rejimi müşteride açık değil')
          if barcode and c.execute('SELECT 1 FROM products WHERE tenant_id=%s AND barcode=%s AND active=true',(d.tenant_id,barcode)).fetchone(): raise HTTPException(409,'Barkod müşteride zaten kayıtlı')
          for sid in d.supplier_ids:
            if not c.execute('SELECT 1 FROM suppliers WHERE id=%s AND tenant_id=%s AND active=true',(sid,d.tenant_id)).fetchone(): raise HTTPException(422,'Tedarikçi müşteriye ait değil')
          item=c.execute('INSERT INTO products(tenant_id,sku,name,barcode,base_uom,regime,units_per_case,case_weight_kg,cases_per_pallet,net_weight_kg,gross_weight_kg,expiry_warning_days) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id,sku,name',(d.tenant_id,sku,name,barcode,d.base_uom,d.regime,d.units_per_case,d.case_weight_kg,d.cases_per_pallet,d.net_weight_kg,d.gross_weight_kg,d.expiry_warning_days)).fetchone()
          for sid in d.supplier_ids: c.execute('INSERT INTO supplier_products(tenant_id,supplier_id,product_id) VALUES(%s,%s,%s)',(d.tenant_id,sid,item['id']))
          c.execute('INSERT INTO master_data_audit(actor_id,entity_type,entity_id,action) VALUES(%s,%s,%s,%s)',(u['id'],'PRODUCT',item['id'],'CREATE'))
          return item
      except psycopg.errors.UniqueViolation: raise HTTPException(409,'Bu müşteride SKU zaten mevcut')

class ProductLink(BaseModel): tenant_id:str; product_id:str; supplier_id:str
@app.post('/api/product-cards/link')
def link_product(d:ProductLink,u=Depends(require('ADMIN'))):
    with db() as c:
      try:
        with c.transaction():
          if not c.execute('SELECT 1 FROM products WHERE id=%s AND tenant_id=%s AND active=true',(d.product_id,d.tenant_id)).fetchone(): raise HTTPException(422,'Ürün seçili müşteriye ait değil')
          if not c.execute('SELECT 1 FROM suppliers WHERE id=%s AND tenant_id=%s AND active=true',(d.supplier_id,d.tenant_id)).fetchone(): raise HTTPException(422,'Tedarikçi seçili müşteriye ait değil')
          c.execute('INSERT INTO supplier_products(tenant_id,supplier_id,product_id) VALUES(%s,%s,%s)',(d.tenant_id,d.supplier_id,d.product_id))
          c.execute('INSERT INTO master_data_audit(actor_id,entity_type,entity_id,action) VALUES(%s,%s,%s,%s)',(u['id'],'PRODUCT',d.product_id,'LINK_SUPPLIER'))
      except psycopg.errors.UniqueViolation: raise HTTPException(409,'Eşleştirme zaten var')
    return {'ok':True}

@app.get('/api/product-cards/expiry-alerts')
def expiry_alerts(u=Depends(require('ADMIN','VIEWER','RECEIVING','PUTAWAY'))):
    with db() as c:
      return c.execute("""SELECT t.name AS customer,p.sku,p.name AS product,l.lot_number,l.expiry_date,
        (l.expiry_date-CURRENT_DATE) AS days_remaining,p.expiry_warning_days,
        CASE WHEN l.expiry_date<CURRENT_DATE THEN 'EXPIRED' ELSE 'WARNING' END AS alert_status,
        SUM(pi.qty) AS qty
        FROM pallet_items pi JOIN products p ON p.id=pi.product_id
        JOIN tenants t ON t.id=pi.tenant_id JOIN lots l ON l.id=pi.lot_id
        JOIN pallets pa ON pa.id=pi.pallet_id
        WHERE l.expiry_date IS NOT NULL AND l.expiry_date<=CURRENT_DATE+p.expiry_warning_days
          AND pi.qty>0 AND pa.status NOT IN ('SHIPPED','REJECTED')
        GROUP BY t.name,p.sku,p.name,l.lot_number,l.expiry_date,p.expiry_warning_days
        ORDER BY l.expiry_date,t.name LIMIT 500""").fetchall()

@app.post('/api/product-cards/import')
async def import_product_cards(tenant_id:str=Form(...), file:UploadFile=File(...), dry_run:bool=Form(True),u=Depends(require('ADMIN'))):
    if not (file.filename or '').lower().endswith('.xlsx'): raise HTTPException(422,'Yalnız .xlsx kabul edilir')
    raw=await file.read(3*1024*1024+1)
    if len(raw)>3*1024*1024: raise HTTPException(413,'Dosya 3 MB sınırını aşıyor')
    try:
        book=load_workbook(io.BytesIO(raw),read_only=True,data_only=True)
        sheet=book.active
        iterator=sheet.iter_rows(values_only=True)
        headers=[str(x or '').strip().lower() for x in next(iterator)]
        required=['sku','urun_adi','barkod','birim','rejim','tedarikci_kodu','koli_ici_adet','koli_agirligi_kg','palet_koli_sayisi','net_kg','brut_kg','skt_uyari_gun']
        if len(set(headers))!=len(headers) or any(k not in headers for k in required): raise ValueError('Şablon sütunları eksik veya tekrarlı')
        rows=[]
        for idx,rawrow in enumerate(iterator,2):
            if idx>2001: raise ValueError('En fazla 2000 ürün satırı yüklenebilir')
            if all(x is None or str(x).strip()=='' for x in rawrow): continue
            rows.append((idx,{k:str(rawrow[headers.index(k)] or '').strip() for k in required}))
    except Exception as e: raise HTTPException(422,'Excel okunamadı: '+str(e)[:180])
    finally:
        try: book.close()
        except Exception: pass
    errors=[]; prepared=[]; seen_sku=set(); seen_barcode=set()
    with db() as c:
      tenant=c.execute('SELECT regimes FROM tenants WHERE id=%s AND active=true',(tenant_id,)).fetchone()
      if not tenant: raise HTTPException(422,'Müşteri bulunamadı')
      suppliers={r['code'].casefold():r['id'] for r in c.execute('SELECT id,code FROM suppliers WHERE tenant_id=%s AND active=true',(tenant_id,))}
      existing_sku={r['sku'].casefold() for r in c.execute('SELECT sku FROM products WHERE tenant_id=%s',(tenant_id,))}
      existing_barcode={r['barcode'] for r in c.execute('SELECT barcode FROM products WHERE tenant_id=%s AND barcode IS NOT NULL AND active=true',(tenant_id,))}
      for number,r in rows:
        issues=[]; sku=r['sku'].casefold(); bc=r['barkod']; sid=suppliers.get(r['tedarikci_kodu'].casefold())
        if not sku or not r['urun_adi']: issues.append('SKU ve ürün adı zorunlu')
        if len(r['sku'])>80 or len(r['urun_adi'])>250: issues.append('Metin uzunluğu sınırı')
        if sku in seen_sku or sku in existing_sku: issues.append('Mükerrer SKU')
        if bc and (bc in seen_barcode or bc in existing_barcode): issues.append('Mükerrer barkod')
        if r['birim'] not in ALLOWED_UNITS: issues.append('Birim ADET/KOLİ/KG olmalı')
        if r['rejim'] not in ALLOWED_REGIMES or r['rejim'] not in tenant['regimes']: issues.append('Müşteriye uygun olmayan rejim')
        if not sid: issues.append('Müşteride tedarikçi kodu bulunamadı')
        for key,integer,minimum in [('koli_ici_adet',True,1),('koli_agirligi_kg',False,0),('palet_koli_sayisi',True,1),('net_kg',False,0),('brut_kg',False,0),('skt_uyari_gun',True,0)]:
          try:
            from decimal import Decimal
            v=Decimal(r[key]) if r[key] else (Decimal(30) if key=='skt_uyari_gun' else None)
            if v is not None and (v<minimum or (not integer and v<=0) or (integer and v!=v.to_integral_value()) or (key=='skt_uyari_gun' and v>3650)): raise ValueError()
            r[key]=int(v) if integer and v is not None else (float(v) if v is not None else None)
          except Exception:
            issues.append(key+' geçersiz')
            r[key]=None
        if r['net_kg'] is not None and r['brut_kg'] is not None and r['brut_kg']<r['net_kg']: issues.append('Brüt kg net kg altında olamaz')
        if issues: errors.append({'satir':number,'hatalar':issues})
        else: prepared.append((r,sid))
        seen_sku.add(sku)
        if bc: seen_barcode.add(bc)
      if errors or dry_run: return {'preview':dry_run,'total':len(rows),'valid':len(prepared),'errors':errors,'imported':0}
      try:
        with c.transaction():
          c.execute('SELECT pg_advisory_xact_lock(hashtext(%s))',(tenant_id,))
          for r,sid in prepared:
            item=c.execute('INSERT INTO products(tenant_id,sku,name,barcode,base_uom,regime,units_per_case,case_weight_kg,cases_per_pallet,net_weight_kg,gross_weight_kg,expiry_warning_days) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id',(tenant_id,r['sku'],r['urun_adi'],r['barkod'] or None,r['birim'],r['rejim'],r['koli_ici_adet'],r['koli_agirligi_kg'],r['palet_koli_sayisi'],r['net_kg'],r['brut_kg'],r['skt_uyari_gun'])).fetchone()
            c.execute('INSERT INTO supplier_products(tenant_id,supplier_id,product_id) VALUES(%s,%s,%s)',(tenant_id,sid,item['id']))
            c.execute('INSERT INTO master_data_audit(actor_id,entity_type,entity_id,action) VALUES(%s,%s,%s,%s)',(u['id'],'PRODUCT',item['id'],'IMPORT'))
      except psycopg.errors.UniqueViolation: raise HTTPException(409,'Yükleme sırasında çakışma; dosyayı yeniden kontrol edin')
    return {'preview':False,'total':len(rows),'valid':len(prepared),'errors':[],'imported':len(prepared)}

class Receive(BaseModel): tenant_id:str; supplier_id:str; warehouse_id:str; document_no:str; barcode:str; qty:Decimal=Field(gt=0); lot_number:str; expiry_date:date; measured_temp:Decimal|None=None; lpn:str|None=None
@app.post('/api/receipts/scan')
def receive(d:Receive,u=Depends(require('RECEIVING'))):
    # Single-transaction receipt; duplicate LPN/doc rejected, no stock credited before QC acceptance.
    with db() as c:
      with c.transaction():
        p=c.execute('SELECT * FROM products WHERE tenant_id=%s AND (barcode=%s OR sku=%s) AND active=true',(d.tenant_id,d.barcode,d.barcode)).fetchone()
        if not p: raise HTTPException(404,'Bu müşterinin ürün kartında barkod tanımlı değil; mal kabul engellendi')
        if not c.execute('SELECT 1 FROM suppliers WHERE id=%s AND tenant_id=%s AND active=true',(d.supplier_id,d.tenant_id)).fetchone(): raise HTTPException(422,'Tedarikçi seçilen müşteriye ait değil')
        if not c.execute('SELECT 1 FROM supplier_products WHERE supplier_id=%s AND product_id=%s AND tenant_id=%s',(d.supplier_id,p['id'],d.tenant_id)).fetchone(): raise HTTPException(422,'Ürün bu müşterinin seçili tedarikçisine tanımlanmamış')
        if not c.execute('SELECT 1 FROM warehouses WHERE id=%s',(d.warehouse_id,)).fetchone(): raise HTTPException(404,'Depo bulunamadı')
        if d.expiry_date<date.today(): raise HTTPException(422,'SKT geçmiş ürün kabul edilemez')
        if d.measured_temp is None: raise HTTPException(422,'Sıcaklık ölçümü zorunlu')
        # Temperature limits are configurable operational policies, not universal food safety thresholds.
        # Receipt is quarantined until authorized QC release.
        try:
            receipt=c.execute("INSERT INTO receipts(tenant_id,supplier_id,warehouse_id,document_no,status,created_by,arrived_at) VALUES(%s,%s,%s,%s,'INSPECTION',%s,now()) RETURNING id",(d.tenant_id,d.supplier_id,d.warehouse_id,d.document_no,u['id'])).fetchone()
            c.execute('INSERT INTO receipt_lines(receipt_id,product_id,expected_qty,accepted_qty,lot_number,expiry_date,measured_temp) VALUES(%s,%s,%s,0,%s,%s,%s)',(receipt['id'],p['id'],d.qty,d.lot_number,d.expiry_date,d.measured_temp))
            lot=c.execute('SELECT id FROM lots WHERE product_id=%s AND lot_number=%s AND expiry_date=%s',(p['id'],d.lot_number,d.expiry_date)).fetchone()
            if not lot: lot=c.execute('INSERT INTO lots(product_id,lot_number,expiry_date) VALUES(%s,%s,%s) RETURNING id',(p['id'],d.lot_number,d.expiry_date)).fetchone()
            pallet_barcode = generate_barcode(c)
            pallet=c.execute("INSERT INTO pallets(lpn,tenant_id,warehouse_id,status) VALUES(%s,%s,%s,'QUARANTINE') RETURNING id",(pallet_barcode,d.tenant_id,d.warehouse_id)).fetchone()
            item_barcode = generate_barcode(c)
            c.execute('INSERT INTO pallet_items(pallet_id,tenant_id,product_id,lot_id,qty,barcode) VALUES(%s,%s,%s,%s,%s,%s)',(pallet['id'],d.tenant_id,p['id'],lot['id'],d.qty,item_barcode))
            c.execute('INSERT INTO audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(%s,%s,%s,%s,%s::jsonb)',(u['id'],'RECEIPT_SCAN','receipt',receipt['id'],'{}'))
        except psycopg.errors.UniqueViolation: raise HTTPException(409,'İrsaliye veya palet barkodu zaten kayıtlı')
        return {'receipt_id':receipt['id'],'pallet_id':pallet['id'],'pallet_barcode':pallet_barcode,'item_barcode':item_barcode,'status':'QUARANTINE','message':'Mal kabul kaydedildi; kalite onayı bekleniyor'}
class Release(BaseModel): pallet_id:str
@app.post('/api/receipts/release')
def release(d:Release,u=Depends(require('ADMIN'))):
    with db() as c:
      with c.transaction():
        p=c.execute('SELECT * FROM pallets WHERE id=%s FOR UPDATE',(d.pallet_id,)).fetchone()
        if not p or p['status']!='QUARANTINE': raise HTTPException(409,'Palet karantinada değil')
        c.execute("UPDATE pallets SET status='RECEIVING' WHERE id=%s",(d.pallet_id,))
        c.execute('INSERT INTO audit_logs(actor_id,action,entity_type,entity_id) VALUES(%s,%s,%s,%s)',(u['id'],'QC_RELEASE','pallet',d.pallet_id))
    return {'status':'RECEIVING'}
class Putaway(BaseModel): lpn:str; location_code:str
@app.post('/api/putaway/scan')
def putaway(d:Putaway,u=Depends(require('PUTAWAY'))):
    with db() as c:
      with c.transaction():
        p=c.execute('SELECT * FROM pallets WHERE lpn=%s FOR UPDATE',(d.lpn,)).fetchone()
        if not p or p['status']!='RECEIVING' or p['location_id']: raise HTTPException(409,'Palet yerleştirmeye uygun değil')
        loc=c.execute('SELECT l.*,z.regime,z.warehouse_id FROM locations l JOIN zones z ON z.id=l.zone_id WHERE l.code=%s AND l.active=true FOR UPDATE OF l',(d.location_code,)).fetchone()
        if not loc or loc['warehouse_id']!=p['warehouse_id']: raise HTTPException(422,'Lokasyon bulunamadı veya depo uyuşmuyor')
        regimes=c.execute('SELECT DISTINCT pr.regime FROM pallet_items pi JOIN products pr ON pr.id=pi.product_id WHERE pi.pallet_id=%s',(p['id'],)).fetchall()
        if loc['regime'] not in [r['regime'] for r in regimes] or len(regimes)!=1: raise HTTPException(422,'Sıcaklık rejimi uyuşmuyor')
        count=c.execute("SELECT count(*) AS n FROM pallets WHERE location_id=%s AND status IN ('AVAILABLE','RESERVED')",(loc['id'],)).fetchone()['n']
        if count>=loc['capacity_pallets']: raise HTTPException(409,'Raf kapasitesi dolu')
        c.execute("UPDATE pallets SET location_id=%s,status='AVAILABLE' WHERE id=%s",(loc['id'],p['id']))
        for item in c.execute('SELECT * FROM pallet_items WHERE pallet_id=%s',(p['id'],)).fetchall():
            c.execute("INSERT INTO stock_movements(tenant_id,product_id,lot_id,pallet_id,to_location_id,qty,movement_type,actor_id) VALUES(%s,%s,%s,%s,%s,%s,'PUTAWAY',%s)",(p['tenant_id'],item['product_id'],item['lot_id'],p['id'],loc['id'],item['qty'],u['id']))
        c.execute('INSERT INTO audit_logs(actor_id,action,entity_type,entity_id) VALUES(%s,%s,%s,%s)',(u['id'],'PUTAWAY','pallet',p['id']))
    return {'status':'AVAILABLE','location':d.location_code}
@app.get('/api/stock')
def stock(u=Depends(actor)):
    with db() as c: return c.execute("SELECT t.name AS customer,pr.sku,pr.name AS product,lo.lot_number,lo.expiry_date,pi.qty,p.lpn,l.code AS location,p.status FROM pallet_items pi JOIN pallets p ON p.id=pi.pallet_id JOIN products pr ON pr.id=pi.product_id JOIN tenants t ON t.id=p.tenant_id JOIN lots lo ON lo.id=pi.lot_id LEFT JOIN locations l ON l.id=p.location_id ORDER BY p.created_at DESC LIMIT 500").fetchall()


# CYNLOG WMS - Code128 barcode endpoint
from fastapi.responses import Response
from barcode import Code128
from barcode.writer import SVGWriter
import io
import re

@app.get("/api/barcodes/{barcode_value}.svg")
def barcode_svg(barcode_value: str):
    if not re.fullmatch(r"[0-9]{12}", barcode_value):
        raise HTTPException(status_code=422, detail="Barkod 12 haneli olmalidir")

    buffer = io.BytesIO()

    barcode = Code128(
        barcode_value,
        writer=SVGWriter()
    )

    barcode.write(
        buffer,
        options={
            "module_width": 0.25,
            "module_height": 15,
            "quiet_zone": 3,
            "font_size": 10,
            "text_distance": 3
        }
    )

    return Response(
        content=buffer.getvalue(),
        media_type="image/svg+xml",
        headers={"Cache-Control": "no-store"}
    )
