provider "aws" {
  region = "us-east-1"
}

# -------------------------------------------------------
# 1. Use EXISTING default VPC
# -------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "sub1" {
  id = tolist(data.aws_subnets.default.ids)[0]
}

data "aws_subnet" "sub2" {
  id = tolist(data.aws_subnets.default.ids)[1]
}

# -------------------------------------------------------
# 2. Security Groups
# -------------------------------------------------------
resource "aws_security_group" "ec2_sg" {
  name   = "cloudnotes-ec2-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cloudnotes-ec2-sg" }
}

resource "aws_security_group" "rds_sg" {
  name   = "cloudnotes-rds-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cloudnotes-rds-sg" }
}

# -------------------------------------------------------
# 3. S3 Bucket
# -------------------------------------------------------
resource "aws_s3_bucket" "storage" {
  bucket        = "cloudnotes-storage-hema-4774636"
  force_destroy = true
  tags          = { Name = "cloudnotes-storage" }
}

# -------------------------------------------------------
# 4. Database Tier (RDS MySQL)
# -------------------------------------------------------
resource "aws_db_subnet_group" "db_sub" {
  name       = "cloudnotes-db-sub"
  subnet_ids = [data.aws_subnet.sub1.id, data.aws_subnet.sub2.id]
}

resource "aws_db_instance" "mysql" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "cloudnotes"
  username               = "admin"
  password               = "password123"
  skip_final_snapshot    = true
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.db_sub.name
  tags                   = { Name = "cloudnotes-mysql" }
}

# -------------------------------------------------------
# 5. Application Tier (EC2)
# -------------------------------------------------------
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  subnet_id                   = data.aws_subnet.sub1.id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  iam_instance_profile        = "LabInstanceProfile"
  associate_public_ip_address = true

  depends_on = [aws_db_instance.mysql]

  user_data = <<-EOF
              #!/bin/bash
              exec > /var/log/user-data.log 2>&1

              # Update and install dependencies
              yum update -y
              yum install -y python3 python3-pip

              # FIX: Install as root so sudo python3 can find the packages
              pip3 install flask pymysql boto3

              # Write the application file
              cat > /home/ec2-user/app.py << 'PYEOF'
from flask import Flask, request, redirect, Response
import pymysql
import pymysql.cursors
import boto3
import time
import urllib.parse
from jinja2 import Environment

app = Flask(__name__)
s3 = boto3.client('s3', region_name='us-east-1')

DB_HOST = "${aws_db_instance.mysql.address}"
BUCKET  = "${aws_s3_bucket.storage.id}"

def get_conn():
    return pymysql.connect(
        host=DB_HOST,
        user="admin",
        password="password123",
        db="cloudnotes",
        connect_timeout=10
    )

def init_db():
    for attempt in range(20):
        try:
            conn = get_conn()
            with conn.cursor() as cur:
                cur.execute(
                    "CREATE TABLE IF NOT EXISTS notes ("
                    "id INT AUTO_INCREMENT PRIMARY KEY, "
                    "title VARCHAR(255) DEFAULT '', "
                    "content TEXT, "
                    "created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "
                    "updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP)"
                )
            conn.commit()
            conn.close()
            print("DB initialized successfully", flush=True)
            return
        except Exception as e:
            print(f"DB not ready (attempt {attempt+1}/20): {e}", flush=True)
            time.sleep(30)
    raise Exception("Could not connect to DB after 20 attempts")

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>CloudNotes</title>
<link href="https://fonts.googleapis.com/css2?family=Syne:wght@400;600;700;800&family=DM+Mono:wght@300;400;500&display=swap" rel="stylesheet">
<style>
  :root{--bg:#0d0d0d;--surface:#161616;--surface2:#1f1f1f;--border:#2a2a2a;--accent:#f5c542;--accent2:#ff6b35;--text:#f0f0f0;--muted:#666;--danger:#ff4444;--success:#44ff88;}
  *{margin:0;padding:0;box-sizing:border-box;}
  body{background:var(--bg);color:var(--text);font-family:'DM Mono',monospace;min-height:100vh;}
  .nav{display:flex;align-items:center;justify-content:space-between;padding:18px 40px;border-bottom:1px solid var(--border);position:sticky;top:0;background:rgba(13,13,13,0.97);backdrop-filter:blur(10px);z-index:100;}
  .logo{font-family:'Syne',sans-serif;font-weight:800;font-size:1.4rem;letter-spacing:-0.5px;}
  .logo span{color:var(--accent);}
  .tabs{display:flex;gap:4px;}
  .tab{padding:8px 20px;border:1px solid var(--border);background:transparent;color:var(--muted);font-family:'DM Mono',monospace;font-size:0.78rem;cursor:pointer;border-radius:4px;transition:all 0.2s;letter-spacing:0.5px;}
  .tab.active,.tab:hover{background:var(--accent);color:#000;border-color:var(--accent);}
  .container{max-width:960px;margin:0 auto;padding:40px 24px;}
  .add-form{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:24px;margin-bottom:32px;}
  .form-title{font-family:'Syne',sans-serif;font-size:0.72rem;letter-spacing:2px;text-transform:uppercase;color:var(--accent);margin-bottom:14px;}
  .form-row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;}
  input[type=text],textarea{background:var(--surface2);border:1px solid var(--border);color:var(--text);font-family:'DM Mono',monospace;font-size:0.85rem;padding:10px 14px;border-radius:4px;outline:none;transition:border-color 0.2s;}
  input[type=text]:focus,textarea:focus{border-color:var(--accent);}
  input[type=text].title-input{flex:1;min-width:180px;}
  textarea.content-input{width:100%;margin-top:10px;resize:vertical;min-height:80px;}
  input[type=file]{font-family:'DM Mono',monospace;font-size:0.8rem;color:var(--muted);flex:1;}
  .btn{padding:10px 22px;border:none;border-radius:4px;font-family:'DM Mono',monospace;font-size:0.8rem;cursor:pointer;transition:all 0.2s;letter-spacing:0.5px;white-space:nowrap;}
  .btn-primary{background:var(--accent);color:#000;font-weight:500;}
  .btn-primary:hover{background:#ffd966;}
  .btn-danger{background:transparent;color:var(--danger);border:1px solid var(--danger);font-size:0.72rem;padding:6px 12px;}
  .btn-danger:hover{background:var(--danger);color:#fff;}
  .btn-edit{background:transparent;color:var(--accent);border:1px solid var(--accent);font-size:0.72rem;padding:6px 12px;}
  .btn-edit:hover{background:var(--accent);color:#000;}
  .btn-download{background:transparent;color:var(--success);border:1px solid var(--success);font-size:0.72rem;padding:6px 12px;}
  .btn-download:hover{background:var(--success);color:#000;}
  .btn-cancel{background:transparent;color:var(--muted);border:1px solid var(--border);}
  .btn-cancel:hover{border-color:var(--muted);color:var(--text);}
  .section-header{display:flex;align-items:center;gap:12px;margin-bottom:18px;}
  .section-label{font-family:'Syne',sans-serif;font-weight:700;font-size:1rem;}
  .count-badge{background:var(--surface2);border:1px solid var(--border);padding:2px 10px;border-radius:20px;font-size:0.72rem;color:var(--muted);}
  .notes-grid{display:grid;gap:12px;}
  .note-card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:18px 20px;transition:border-color 0.2s;}
  .note-card:hover{border-color:var(--accent);}
  .note-header{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin-bottom:8px;}
  .note-title{font-family:'Syne',sans-serif;font-weight:600;font-size:0.95rem;}
  .note-content{font-size:0.82rem;color:var(--muted);line-height:1.65;white-space:pre-wrap;}
  .note-meta{font-size:0.68rem;color:#444;margin-top:10px;}
  .note-actions{display:flex;gap:6px;flex-shrink:0;}
  .modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,0.85);z-index:200;align-items:center;justify-content:center;}
  .modal-overlay.open{display:flex;}
  .modal{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:28px;width:90%;max-width:520px;}
  .modal h3{font-family:'Syne',sans-serif;font-size:1rem;margin-bottom:16px;color:var(--accent);}
  .modal-actions{display:flex;gap:8px;margin-top:16px;justify-content:flex-end;}
  .file-list{display:grid;gap:10px;}
  .file-card{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:14px 18px;display:flex;align-items:center;justify-content:space-between;gap:12px;transition:border-color 0.2s;}
  .file-card:hover{border-color:var(--accent2);}
  .file-info{flex:1;}
  .file-name{font-size:0.85rem;color:var(--text);}
  .file-size{font-size:0.7rem;color:var(--muted);margin-top:3px;}
  .file-actions{display:flex;gap:6px;}
  .empty{text-align:center;padding:60px 20px;color:var(--muted);font-size:0.85rem;}
  .empty-icon{font-size:2.5rem;margin-bottom:12px;opacity:0.3;}
  .toast{position:fixed;bottom:24px;right:24px;background:var(--surface2);border:1px solid var(--border);border-left:3px solid var(--accent);padding:12px 20px;border-radius:6px;font-size:0.8rem;opacity:0;transform:translateY(10px);transition:all 0.3s;z-index:300;}
  .toast.show{opacity:1;transform:translateY(0);}
  .panel{display:none;}
  .panel.active{display:block;}
</style>
</head>
<body>
<nav class="nav">
  <div class="logo">Cloud<span>Notes</span></div>
  <div class="tabs">
    <button class="tab active" onclick="switchTab('notes',this)">&#128221; Notes</button>
    <button class="tab" onclick="switchTab('files',this)">&#128193; Files</button>
  </div>
</nav>
<div class="container">
  <div id="notes-panel" class="panel active">
    <div class="add-form">
      <div class="form-title">+ New Note</div>
      <form method="POST" action="/notes/add">
        <div class="form-row">
          <input type="text" name="title" class="title-input" placeholder="Note title..." required>
          <button type="submit" class="btn btn-primary">Save Note</button>
        </div>
        <textarea name="content" class="content-input" placeholder="Write your note here..."></textarea>
      </form>
    </div>
    <div class="section-header">
      <span class="section-label">Your Notes</span>
      <span class="count-badge">{{ notes|length }} notes</span>
    </div>
    {% if notes %}
    <div class="notes-grid">
      {% for note in notes %}
      <div class="note-card">
        <div class="note-header">
          <div class="note-title">{{ note.title or 'Untitled' }}</div>
          <div class="note-actions">
            <button class="btn btn-edit" onclick="openEdit({{ note.id }},'{{ note.title|e }}',`{{ note.content|e }}`)">Edit</button>
            <form method="POST" action="/notes/delete/{{ note.id }}" style="display:inline">
              <button type="submit" class="btn btn-danger" onclick="return confirm('Delete this note?')">Delete</button>
            </form>
          </div>
        </div>
        <div class="note-content">{{ note.content }}</div>
        <div class="note-meta">Created: {{ note.created_at }} &nbsp;&middot;&nbsp; Updated: {{ note.updated_at }}</div>
      </div>
      {% endfor %}
    </div>
    {% else %}
    <div class="empty"><div class="empty-icon">&#128221;</div>No notes yet. Add your first note above.</div>
    {% endif %}
  </div>
  <div id="files-panel" class="panel">
    <div class="add-form">
      <div class="form-title">+ Upload File</div>
      <form method="POST" action="/files/upload" enctype="multipart/form-data">
        <div class="form-row">
          <input type="file" name="file" required>
          <button type="submit" class="btn btn-primary">Upload</button>
        </div>
      </form>
    </div>
    <div class="section-header">
      <span class="section-label">Your Files</span>
      <span class="count-badge">{{ files|length }} files</span>
    </div>
    {% if files %}
    <div class="file-list">
      {% for f in files %}
      <div class="file-card">
        <div style="font-size:1.2rem">&#128196;</div>
        <div class="file-info">
          <div class="file-name">{{ f.Key }}</div>
          <div class="file-size">{{ (f.Size / 1024)|round(1) }} KB &nbsp;&middot;&nbsp; {{ f.LastModified.strftime('%Y-%m-%d %H:%M') }}</div>
        </div>
        <div class="file-actions">
          <a href="/files/download/{{ f.Key|urlencode }}" class="btn btn-download">Download</a>
          <form method="POST" action="/files/delete/{{ f.Key|urlencode }}" style="display:inline">
            <button type="submit" class="btn btn-danger" onclick="return confirm('Delete this file?')">Delete</button>
          </form>
        </div>
      </div>
      {% endfor %}
    </div>
    {% else %}
    <div class="empty"><div class="empty-icon">&#128193;</div>No files uploaded yet.</div>
    {% endif %}
  </div>
</div>
<div class="modal-overlay" id="edit-modal">
  <div class="modal">
    <h3>&#9999;&#65039; Edit Note</h3>
    <form method="POST" id="edit-form" action="">
      <input type="text" name="title" id="edit-title" class="title-input" style="width:100%;margin-bottom:10px" placeholder="Title">
      <textarea name="content" id="edit-content" class="content-input" style="min-height:130px" placeholder="Content"></textarea>
      <div class="modal-actions">
        <button type="button" class="btn btn-cancel" onclick="closeEdit()">Cancel</button>
        <button type="submit" class="btn btn-primary">Save Changes</button>
      </div>
    </form>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
  function switchTab(tab,el){
    document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));
    document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));
    el.classList.add('active');
    document.getElementById(tab+'-panel').classList.add('active');
  }
  function openEdit(id,title,content){
    document.getElementById('edit-form').action='/notes/edit/'+id;
    document.getElementById('edit-title').value=title;
    document.getElementById('edit-content').value=content;
    document.getElementById('edit-modal').classList.add('open');
  }
  function closeEdit(){document.getElementById('edit-modal').classList.remove('open');}
  function showToast(msg){
    const t=document.getElementById('toast');
    t.textContent=msg;t.classList.add('show');
    setTimeout(()=>t.classList.remove('show'),3000);
  }
  const params=new URLSearchParams(window.location.search);
  if(params.get('msg'))showToast(decodeURIComponent(params.get('msg')));
  if(params.get('tab')==='files')switchTab('files',document.querySelectorAll('.tab')[1]);
</script>
</body>
</html>"""

@app.route('/')
def index():
    conn = get_conn()
    with conn.cursor(pymysql.cursors.DictCursor) as cur:
        cur.execute("SELECT id, title, content, created_at, updated_at FROM notes ORDER BY id DESC")
        notes = cur.fetchall()
    conn.close()
    files = s3.list_objects_v2(Bucket=BUCKET).get('Contents', [])
    env = Environment()
    env.filters['urlencode'] = lambda s: urllib.parse.quote(str(s), safe='')
    tmpl = env.from_string(HTML_TEMPLATE)
    return tmpl.render(notes=notes, files=files)

@app.route('/notes/add', methods=['POST'])
def add_note():
    title   = request.form.get('title', '')
    content = request.form.get('content', '')
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("INSERT INTO notes (title, content) VALUES (%s, %s)", (title, content))
    conn.commit()
    conn.close()
    return redirect('/?msg=Note+saved+successfully')

@app.route('/notes/edit/<int:note_id>', methods=['POST'])
def edit_note(note_id):
    title   = request.form.get('title', '')
    content = request.form.get('content', '')
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("UPDATE notes SET title=%s, content=%s WHERE id=%s", (title, content, note_id))
    conn.commit()
    conn.close()
    return redirect('/?msg=Note+updated')

@app.route('/notes/delete/<int:note_id>', methods=['POST'])
def delete_note(note_id):
    conn = get_conn()
    with conn.cursor() as cur:
        cur.execute("DELETE FROM notes WHERE id=%s", (note_id,))
    conn.commit()
    conn.close()
    return redirect('/?msg=Note+deleted')

@app.route('/files/upload', methods=['POST'])
def upload_file():
    file = request.files.get('file')
    if file and file.filename:
        s3.upload_fileobj(file, BUCKET, file.filename)
        return redirect('/?tab=files&msg=File+uploaded+successfully')
    return redirect('/?tab=files&msg=No+file+selected')

@app.route('/files/download/<path:filename>')
def download_file(filename):
    obj = s3.get_object(Bucket=BUCKET, Key=filename)
    return Response(
        obj['Body'].read(),
        headers={
            'Content-Disposition': f'attachment; filename="{filename}"',
            'Content-Type': obj.get('ContentType', 'application/octet-stream')
        }
    )

@app.route('/files/delete/<path:filename>', methods=['POST'])
def delete_file(filename):
    s3.delete_object(Bucket=BUCKET, Key=filename)
    return redirect('/?tab=files&msg=File+deleted')

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=80)
PYEOF

              # FIX: Set correct permissions
              chmod 644 /home/ec2-user/app.py

              # FIX: Start app directly as root (user_data runs as root already)
              # No 'sudo' needed — and root's python3 has the pip-installed packages
              nohup python3 /home/ec2-user/app.py > /var/log/app.log 2>&1 &

              echo "user-data script completed successfully"
              EOF

  tags = { Name = "cloudnotes-app" }
}

# -------------------------------------------------------
# Outputs
# -------------------------------------------------------
output "app_url" {
  value       = "http://${aws_instance.app.public_ip}"
  description = "CloudNotes application URL"
}

output "rds_endpoint" {
  value       = aws_db_instance.mysql.address
  description = "RDS MySQL endpoint"
}

output "s3_bucket" {
  value       = aws_s3_bucket.storage.id
  description = "S3 bucket name"
}
