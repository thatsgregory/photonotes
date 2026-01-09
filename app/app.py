import os
import boto3
import ydb
import uuid
from flask import Flask, render_template_string, request, redirect, url_for
from werkzeug.utils import secure_filename

app = Flask(__name__)

# Переменные окружения
YDB_ENDPOINT = os.getenv('YDB_ENDPOINT')
YDB_DATABASE = os.getenv('YDB_DATABASE')
BUCKET_NAME = os.getenv('BUCKET_NAME')
AWS_ACCESS_KEY_ID = os.getenv('AWS_ACCESS_KEY_ID')
AWS_SECRET_ACCESS_KEY = os.getenv('AWS_SECRET_ACCESS_KEY')
REGION = 'ru-central1'

# S3 Клиент
s3 = boto3.client(
    's3',
    endpoint_url='https://storage.yandexcloud.net',
    aws_access_key_id=AWS_ACCESS_KEY_ID,
    aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    region_name=REGION
)

# YDB Драйвер
driver = ydb.Driver(endpoint=YDB_ENDPOINT, database=YDB_DATABASE)
driver.wait(timeout=10)

def get_session():
    return driver.table_client.session().create()

# === ШАБЛОН ГЛАВНОЙ СТРАНИЦЫ ===
HTML_TEMPLATE = """
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><title>PhotoNotes</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head><body class="bg-light"><div class="container py-5">
  <h1 class="mb-4">PhotoNotes Cloud</h1>
  
  <!-- Форма добавления -->
  <div class="card mb-4 p-3">
      <form action="/add" method="post" enctype="multipart/form-data">
        <div class="input-group">
            <input type="text" name="title" placeholder="Заголовок заметки" class="form-control" required>
            <input type="file" name="file" class="form-control" required>
            <button type="submit" class="btn btn-primary">Загрузить</button>
        </div>
      </form>
  </div>

  <!-- Список заметок -->
  <div class="row">
    {% for note in notes %}
    <div class="col-md-4 mb-3">
        <div class="card h-100">
            <img src="{{ note.image_url }}" class="card-img-top" style="height:200px;object-fit:cover;">
            <div class="card-body">
                <h5 class="card-title">{{ note.title }}</h5>
                
                <div class="d-flex justify-content-between mt-3">
                    <!-- Кнопка Редактировать (UPDATE) -->
                    <a href="/edit/{{ note.id }}" class="btn btn-outline-secondary btn-sm">Редактировать</a>
                    
                    <!-- Кнопка Удалить (DELETE) -->
                    <form action="/delete/{{ note.id }}" method="post" style="display:inline;">
                       <button type="submit" class="btn btn-danger btn-sm">Удалить</button>
                    </form>
                </div>
            </div>
        </div>
    </div>
    {% endfor %}
  </div>
</div></body></html>
"""

# === ШАБЛОН СТРАНИЦЫ РЕДАКТИРОВАНИЯ ===
EDIT_TEMPLATE = """
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><title>Редактирование</title>
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head><body class="bg-light"><div class="container py-5" style="max-width: 600px;">
  <div class="card">
    <div class="card-header">Редактирование заметки</div>
    <div class="card-body">
        <img src="{{ image_url }}" class="img-fluid mb-3 rounded">
        <form action="/edit/{{ id }}" method="post">
            <div class="mb-3">
                <label class="form-label">Новый заголовок</label>
                <input type="text" name="title" value="{{ title }}" class="form-control" required>
            </div>
            <div class="d-flex justify-content-between">
                <a href="/" class="btn btn-secondary">Отмена</a>
                <button type="submit" class="btn btn-success">Сохранить</button>
            </div>
        </form>
    </div>
  </div>
</div></body></html>
"""

@app.route('/')
def index():
    session = get_session()
    try:
        # READ: Чтение списка
        result_sets = session.transaction().execute("SELECT * FROM notes;", commit_tx=True)
        notes = []
        if result_sets and result_sets[0].rows:
            for row in result_sets[0].rows:
                notes.append({
                    'id': row.id,
                    'title': row.title,
                    'image_url': row.image_url
                })
        return render_template_string(HTML_TEMPLATE, notes=notes)
    except Exception as e:
        return f"Error: {str(e)}"

@app.route('/add', methods=['POST'])
def add():
    # CREATE: Создание новой записи
    title = request.form['title']
    file = request.files['file']
    if file:
        file_id = str(uuid.uuid4())
        filename = f"{file_id}.jpg"
        s3.upload_fileobj(file, BUCKET_NAME, filename)
        image_url = f"https://storage.yandexcloud.net/{BUCKET_NAME}/{filename}"
        
        session = get_session()
        query = f'UPSERT INTO notes (id, title, image_url) VALUES ("{file_id}", "{title}", "{image_url}");'
        session.transaction().execute(query, commit_tx=True)
    return redirect(url_for('index'))

@app.route('/edit/<id>', methods=['GET', 'POST'])
def edit_note(id):
    session = get_session()
    
    if request.method == 'POST':
        # UPDATE: Обновление записи в БД
        new_title = request.form['title']
        query = f'UPDATE notes SET title = "{new_title}" WHERE id = "{id}";'
        session.transaction().execute(query, commit_tx=True)
        return redirect(url_for('index'))
    
    else:
        # READ (Single): Получение данных одной заметки для формы
        query = f'SELECT * FROM notes WHERE id = "{id}";'
        result_sets = session.transaction().execute(query, commit_tx=True)
        if not result_sets or not result_sets[0].rows:
            return "Note not found", 404
            
        row = result_sets[0].rows[0]
        return render_template_string(EDIT_TEMPLATE, id=id, title=row.title, image_url=row.image_url)

@app.route('/delete/<id>', methods=['POST'])
def delete(id):
    # DELETE: Удаление записи и файла
    try:
        filename = f"{id}.jpg"
        s3.delete_object(Bucket=BUCKET_NAME, Key=filename)
    except:
        pass

    session = get_session()
    query = f'DELETE FROM notes WHERE id = "{id}";'
    session.transaction().execute(query, commit_tx=True)
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
