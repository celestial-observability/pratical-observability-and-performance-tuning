package main

import (
	"context"
	crand "crypto/rand"
	"crypto/sha512"
	"encoding/hex"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/XSAM/otelsql"
	"github.com/bradfitz/gomemcache/memcache"
	gsm "github.com/bradleypeabody/gorilla-sessions-memcache"
	"github.com/go-chi/chi/v5"
	_ "github.com/go-sql-driver/mysql"
	"github.com/gorilla/sessions"
	"github.com/grafana/pyroscope-go"
	"github.com/jmoiron/sqlx"
	"github.com/riandyrn/otelchi"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.37.0"
)

var (
	db    *sqlx.DB
	store *gsm.MemcacheStore
)

const (
	postsPerPage  = 20
	ISO8601Format = "2006-01-02T15:04:05-07:00"
	UploadLimit   = 10 * 1024 * 1024 // 10mb
)

type User struct {
	ID          int       `db:"id"`
	AccountName string    `db:"account_name"`
	Passhash    string    `db:"passhash"`
	Authority   int       `db:"authority"`
	DelFlg      int       `db:"del_flg"`
	CreatedAt   time.Time `db:"created_at"`
}

type Post struct {
	ID           int       `db:"id"`
	UserID       int       `db:"user_id"`
	Imgdata      []byte    `db:"imgdata"`
	Body         string    `db:"body"`
	Mime         string    `db:"mime"`
	CreatedAt    time.Time `db:"created_at"`
	CommentCount int
	Comments     []Comment
	User         User
	CSRFToken    string
}

type Comment struct {
	ID              int       `db:"id"`
	PostID          int       `db:"post_id"`
	Comment         string    `db:"comment"`
	CreatedAt       time.Time `db:"created_at"`
	UserAccountName string    `db:"user_account_name"`
}

// postsとusersの結合結果用の構造体
type PostUser struct {
	PostID        int       `db:"post_id"`
	PostUserID    int       `db:"post_user_id"`
	PostImgdata   []byte    `db:"post_imgdata"`
	PostBody      string    `db:"post_body"`
	PostMime      string    `db:"post_mime"`
	PostCreatedAt time.Time `db:"post_created_at"`

	UserID          int       `db:"user_id"`
	UserAccountName string    `db:"user_account_name"`
	UserPasshash    string    `db:"user_passhash"`
	UserAuthority   int       `db:"user_authority"`
	UserDelFlg      int       `db:"user_del_flg"`
	UserCreatedAt   time.Time `db:"user_created_at"`
}

// 各PostUserからUserを含むPostを組み立てる
func buildPosts(postUsers []PostUser) []Post {
	posts := make([]Post, len(postUsers))
	for i, pu := range postUsers {
		posts[i] = Post{
			ID:        pu.PostID,
			UserID:    pu.UserID,
			Imgdata:   pu.PostImgdata,
			Body:      pu.PostBody,
			Mime:      pu.PostMime,
			CreatedAt: pu.PostCreatedAt,

			User: User{
				ID:          pu.UserID,
				AccountName: pu.UserAccountName,
				Passhash:    pu.UserPasshash,
				Authority:   pu.UserAuthority,
				DelFlg:      pu.UserDelFlg,
				CreatedAt:   pu.UserCreatedAt,
			},
		}
	}
	return posts
}

func init() {
	memdAddr := os.Getenv("ISUCONP_MEMCACHED_ADDRESS")
	if memdAddr == "" {
		memdAddr = "localhost:11211"
	}
	memcacheClient := memcache.New(memdAddr)
	store = gsm.NewMemcacheStore(memcacheClient, "iscogram_", []byte("sendagaya"))
	log.SetFlags(log.Ldate | log.Ltime | log.Lshortfile)
}

func dbInitialize(ctx context.Context) {
	sqls := []string{
		"DELETE FROM users WHERE id > 1000",
		"DELETE FROM posts WHERE id > 10000",
		"DELETE FROM comments WHERE id > 100000",
		"UPDATE users SET del_flg = 0",
		"UPDATE users SET del_flg = 1 WHERE id % 50 = 0",
	}

	for _, sql := range sqls {
		db.ExecContext(ctx, sql)
	}
}

func initTracer() func() {
	ctx := context.Background()

	otlpEndpoint := "localhost:4318"

	exporter, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(otlpEndpoint),
		otlptracehttp.WithHeaders(map[string]string{
			"Accept": "*/*",
		}),
		otlptracehttp.WithCompression(otlptracehttp.GzipCompression),
		otlptracehttp.WithInsecure(),
	)
	if err != nil {
		log.Fatalf("Failed to create OTLP exporter: %v", err)
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName("my-webapp"),
		),
	)
	if err != nil {
		log.Fatalf("Failed to create resource: %v", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	return func() {
		if err := tp.Shutdown(ctx); err != nil {
			log.Printf("Error shutting down tracer procider: %v", err)
		}
	}
}

func tryLogin(ctx context.Context, accountName, password string) *User {
	u := User{}
	err := db.GetContext(ctx, &u, "SELECT * FROM users WHERE account_name = ? AND del_flg = 0", accountName)
	if err != nil {
		return nil
	}

	if calculatePasshash(u.AccountName, password) == u.Passhash {
		return &u
	} else {
		return nil
	}
}

func validateUser(accountName, password string) bool {
	return regexp.MustCompile(`\A[0-9a-zA-Z_]{3,}\z`).MatchString(accountName) &&
		regexp.MustCompile(`\A[0-9a-zA-Z_]{6,}\z`).MatchString(password)
}

// 今回のGo実装では言語側のエスケープの仕組みが使えないのでOSコマンドインジェクション対策できない
// 取り急ぎPHPのescapeshellarg関数を参考に自前で実装
// cf: http://jp2.php.net/manual/ja/function.escapeshellarg.php
func escapeshellarg(arg string) string {
	return "'" + strings.Replace(arg, "'", "'\\''", -1) + "'"
}

func digest(src string) string {
	hash := sha512.Sum512([]byte(src))
	return hex.EncodeToString(hash[:])
}

func calculateSalt(accountName string) string {
	return digest(accountName)
}

func calculatePasshash(accountName, password string) string {
	return digest(password + ":" + calculateSalt(accountName))
}

func getSession(r *http.Request) *sessions.Session {
	session, _ := store.Get(r, "isuconp-go.session")

	return session
}

func getSessionUser(ctx context.Context, r *http.Request) User {
	session := getSession(r)
	uid, ok := session.Values["user_id"]
	if !ok || uid == nil {
		return User{}
	}

	u := User{}

	err := db.GetContext(ctx, &u, "SELECT * FROM `users` WHERE `id` = ?", uid)
	if err != nil {
		return User{}
	}

	return u
}

func getFlash(w http.ResponseWriter, r *http.Request, key string) string {
	session := getSession(r)
	value, ok := session.Values[key]

	if !ok || value == nil {
		return ""
	} else {
		delete(session.Values, key)
		session.Save(r, w)
		return value.(string)
	}
}

func makePostsNew(ctx context.Context, results []Post, csrfToken string, allComments bool) ([]Post, error) {
	if len(results) == 0 {
		return []Post{}, nil
	}
	var posts []Post

	rawQuery := `
SELECT
  id
  , post_id
  , comment
  , created_at
  , user_account_name
FROM comments
WHERE post_id IN (?)
ORDER BY created_at DESC
`

	// コメントをまとめて取得
	postIds := make([]int, len(results))
	for i, p := range results {
		postIds[i] = p.ID
	}
	query, args, err := sqlx.In(rawQuery, postIds)
	if err != nil {
		fmt.Println("コメントをまとめて取得で失敗1:", err)
		return nil, err
	}
	query = db.Rebind(query)
	var allPostComments []Comment
	err = db.SelectContext(ctx, &allPostComments, query, args...)
	if err != nil {
		fmt.Println("コメントをまとめて取得で失敗2:", err)
		return nil, err
	}

	commentsMap := map[int][]Comment{}
	for _, c := range allPostComments {
		commentsMap[c.PostID] = append(commentsMap[c.PostID], c)
	}

	for _, p := range results {
		comments := commentsMap[p.ID]
		p.CommentCount = len(comments)

		if !allComments {
			limit := len(comments)
			if limit > 3 {
				limit = 3
			}
			comments = comments[:limit]
		}

		// reverse
		for i, j := 0, len(comments)-1; i < j; i, j = i+1, j-1 {
			comments[i], comments[j] = comments[j], comments[i]
		}

		p.Comments = comments

		p.CSRFToken = csrfToken

		posts = append(posts, p)
	}

	return posts, nil
}

func imageURL(p Post) string {
	ext := ""
	if p.Mime == "image/jpeg" {
		ext = ".jpg"
	} else if p.Mime == "image/png" {
		ext = ".png"
	} else if p.Mime == "image/gif" {
		ext = ".gif"
	}

	return "/image/" + strconv.Itoa(p.ID) + ext
}

func isLogin(u User) bool {
	return u.ID != 0
}

func getCSRFToken(r *http.Request) string {
	session := getSession(r)
	csrfToken, ok := session.Values["csrf_token"]
	if !ok {
		return ""
	}
	return csrfToken.(string)
}

func secureRandomStr(b int) string {
	k := make([]byte, b)
	if _, err := crand.Read(k); err != nil {
		panic(err)
	}
	return fmt.Sprintf("%x", k)
}

func getTemplPath(filename string) string {
	return path.Join("templates", filename)
}

func getInitialize(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	dbInitialize(ctx)
	cleanupImages()
	w.WriteHeader(http.StatusOK)
}

func getLogin(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me := getSessionUser(ctx, r)

	if isLogin(me) {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	template.Must(template.ParseFiles(
		getTemplPath("layout.html"),
		getTemplPath("login.html")),
	).Execute(w, struct {
		Me    User
		Flash string
	}{me, getFlash(w, r, "notice")})
}

func postLogin(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if isLogin(getSessionUser(ctx, r)) {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	u := tryLogin(ctx, r.FormValue("account_name"), r.FormValue("password"))

	if u != nil {
		session := getSession(r)
		session.Values["user_id"] = u.ID
		session.Values["csrf_token"] = secureRandomStr(16)
		session.Save(r, w)

		http.Redirect(w, r, "/", http.StatusFound)
	} else {
		session := getSession(r)
		session.Values["notice"] = "アカウント名かパスワードが間違っています"
		session.Save(r, w)

		http.Redirect(w, r, "/login", http.StatusFound)
	}
}

func getRegister(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if isLogin(getSessionUser(ctx, r)) {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	template.Must(template.ParseFiles(
		getTemplPath("layout.html"),
		getTemplPath("register.html")),
	).Execute(w, struct {
		Me    User
		Flash string
	}{User{}, getFlash(w, r, "notice")})
}

func postRegister(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if isLogin(getSessionUser(ctx, r)) {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	accountName, password := r.FormValue("account_name"), r.FormValue("password")

	validated := validateUser(accountName, password)
	if !validated {
		session := getSession(r)
		session.Values["notice"] = "アカウント名は3文字以上、パスワードは6文字以上である必要があります"
		session.Save(r, w)

		http.Redirect(w, r, "/register", http.StatusFound)
		return
	}

	exists := 0
	// ユーザーが存在しない場合はエラーになるのでエラーチェックはしない
	db.GetContext(ctx, &exists, "SELECT 1 FROM users WHERE `account_name` = ?", accountName)

	if exists == 1 {
		session := getSession(r)
		session.Values["notice"] = "アカウント名がすでに使われています"
		session.Save(r, w)

		http.Redirect(w, r, "/register", http.StatusFound)
		return
	}

	query := "INSERT INTO `users` (`account_name`, `passhash`) VALUES (?,?)"
	result, err := db.ExecContext(ctx, query, accountName, calculatePasshash(accountName, password))
	if err != nil {
		log.Print(err)
		return
	}

	session := getSession(r)
	uid, err := result.LastInsertId()
	if err != nil {
		log.Print(err)
		return
	}
	session.Values["user_id"] = uid
	session.Values["csrf_token"] = secureRandomStr(16)
	session.Save(r, w)

	http.Redirect(w, r, "/", http.StatusFound)
}

func getLogout(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	delete(session.Values, "user_id")
	session.Options = &sessions.Options{MaxAge: -1}
	session.Save(r, w)

	http.Redirect(w, r, "/", http.StatusFound)
}

func getIndex(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me := getSessionUser(ctx, r)

	results := []Post{}
	postUsers := []PostUser{}

	query := `
SELECT /*+ NO_INDEX(posts user_id_and_created_at_idx) */
  posts.id as post_id
  , posts.user_id as post_user_id
  , posts.body as post_body
  , posts.mime as post_mime
  , posts.created_at as post_created_at

  , users.id as user_id
  , users.account_name as user_account_name
  , users.passhash as user_passhash
  , users.authority as user_authority
  , users.del_flg as user_del_flg
  , users.created_at as user_created_at
FROM posts
JOIN users ON posts.user_id = users.id
WHERE users.del_flg = 0
ORDER BY posts.created_at DESC
LIMIT 20
`
	err := db.SelectContext(ctx, &postUsers, query)
	if err != nil {
		log.Print(err)
		return
	}
	results = buildPosts(postUsers)

	posts, err := makePostsNew(ctx, results, getCSRFToken(r), false)
	if err != nil {
		log.Print(err)
		return
	}

	noticeMessage := getFlash(w, r, "notice")
	csrfToken := getCSRFToken(r)
	layoutHtml(w, me, func(w2 io.Writer) {
		indexHtml(w2, posts, csrfToken, noticeMessage)
	})
}

func getAccountName(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	accountName := r.PathValue("accountName")
	user := User{}

	err := db.GetContext(ctx, &user, "SELECT * FROM `users` WHERE `account_name` = ? AND `del_flg` = 0", accountName)
	if err != nil {
		log.Print(err)
		return
	}

	if user.ID == 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	results := []Post{}
	postUsers := []PostUser{}

	query := `
SELECT
  posts.id as post_id
  , posts.user_id as post_user_id
  , posts.body as post_body
  , posts.mime as post_mime
  , posts.created_at as post_created_at

  , users.id as user_id
  , users.account_name as user_account_name
  , users.passhash as user_passhash
  , users.authority as user_authority
  , users.del_flg as user_del_flg
  , users.created_at as user_created_at
FROM posts
JOIN users ON posts.user_id = users.id
WHERE posts.user_id = ?
ORDER BY posts.created_at DESC
LIMIT 20
`
	err = db.SelectContext(ctx, &postUsers, query, user.ID)
	if err != nil {
		log.Print(err)
		return
	}
	results = buildPosts(postUsers)

	posts, err := makePostsNew(ctx, results, getCSRFToken(r), false)
	if err != nil {
		log.Print(err)
		return
	}

	commentCount := 0
	err = db.GetContext(ctx, &commentCount, "SELECT COUNT(*) AS count FROM `comments` WHERE `user_id` = ?", user.ID)
	if err != nil {
		log.Print(err)
		return
	}

	postIDs := []int{}
	err = db.SelectContext(ctx, &postIDs, "SELECT `id` FROM `posts` WHERE `user_id` = ?", user.ID)
	if err != nil {
		log.Print(err)
		return
	}
	postCount := len(postIDs)

	commentedCount := 0
	if postCount > 0 {
		s := []string{}
		for range postIDs {
			s = append(s, "?")
		}
		placeholder := strings.Join(s, ", ")

		// convert []int -> []any
		args := make([]any, len(postIDs))
		for i, v := range postIDs {
			args[i] = v
		}

		err = db.GetContext(ctx, &commentedCount, "SELECT COUNT(*) AS count FROM `comments` WHERE `post_id` IN ("+placeholder+")", args...)
		if err != nil {
			log.Print(err)
			return
		}
	}

	me := getSessionUser(ctx, r)

	layoutHtml(w, me, func(w2 io.Writer) {
		userHtml(w2, posts, user, postCount, commentCount, commentedCount)
	})
}

func getPosts(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	m, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		log.Print(err)
		return
	}
	maxCreatedAt := m.Get("max_created_at")
	if maxCreatedAt == "" {
		return
	}

	t, err := time.Parse(ISO8601Format, maxCreatedAt)
	if err != nil {
		log.Print(err)
		return
	}

	results := []Post{}
	postUsers := []PostUser{}

	query := `
SELECT /*+ NO_INDEX(posts user_id_and_created_at_idx) */
  posts.id as post_id
  , posts.user_id as post_user_id
  , posts.body as post_body
  , posts.mime as post_mime
  , posts.created_at as post_created_at

  , users.id as user_id
  , users.account_name as user_account_name
  , users.passhash as user_passhash
  , users.authority as user_authority
  , users.del_flg as user_del_flg
  , users.created_at as user_created_at
FROM posts
JOIN users ON posts.user_id = users.id
WHERE posts.created_at <= ?
  AND users.del_flg = 0
ORDER BY posts.created_at DESC
LIMIT 20
`

	err = db.SelectContext(ctx, &postUsers, query, t.Format(ISO8601Format))
	if err != nil {
		log.Print(err)
		return
	}
	results = buildPosts(postUsers)

	posts, err := makePostsNew(ctx, results, getCSRFToken(r), false)
	if err != nil {
		log.Print(err)
		return
	}

	if len(posts) == 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	postsHtml(w, posts)
}

func getPostsID(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	pidStr := r.PathValue("id")
	pid, err := strconv.Atoi(pidStr)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	results := []Post{}
	postUsers := []PostUser{}

	query := `
SELECT /*+ NO_INDEX(posts user_id_and_created_at_idx) */
  posts.id as post_id
  , posts.user_id as post_user_id
  , posts.body as post_body
  , posts.mime as post_mime
  , posts.created_at as post_created_at

  , users.id as user_id
  , users.account_name as user_account_name
  , users.passhash as user_passhash
  , users.authority as user_authority
  , users.del_flg as user_del_flg
  , users.created_at as user_created_at
FROM posts
JOIN users ON posts.user_id = users.id
WHERE posts.id = ?
  AND users.del_flg = 0
`

	err = db.SelectContext(ctx, &postUsers, query, pid)
	if err != nil {
		log.Print(err)
		return
	}
	results = buildPosts(postUsers)

	posts, err := makePostsNew(ctx, results, getCSRFToken(r), true)
	if err != nil {
		log.Print(err)
		return
	}

	if len(posts) == 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	p := posts[0]

	me := getSessionUser(ctx, r)

	layoutHtml(w, me, func(w2 io.Writer) {
		postHtml(w2, p)
	})
}

func postIndex(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me := getSessionUser(ctx, r)
	if !isLogin(me) {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}

	if r.FormValue("csrf_token") != getCSRFToken(r) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		session := getSession(r)
		session.Values["notice"] = "画像が必須です"
		session.Save(r, w)

		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	mime := ""
	ext := ""
	if file != nil {
		// 投稿のContent-Typeからファイルのタイプを決定する
		contentType := header.Header["Content-Type"][0]
		if strings.Contains(contentType, "jpeg") {
			mime = "image/jpeg"
			ext = "jpg"
		} else if strings.Contains(contentType, "png") {
			mime = "image/png"
			ext = "png"
		} else if strings.Contains(contentType, "gif") {
			mime = "image/gif"
			ext = "gif"
		} else {
			session := getSession(r)
			session.Values["notice"] = "投稿できる画像形式はjpgとpngとgifだけです"
			session.Save(r, w)

			http.Redirect(w, r, "/", http.StatusFound)
			return
		}
	}

	filedata, err := io.ReadAll(file)
	if err != nil {
		log.Print(err)
		return
	}

	if len(filedata) > UploadLimit {
		session := getSession(r)
		session.Values["notice"] = "ファイルサイズが大きすぎます"
		session.Save(r, w)

		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	query := "INSERT INTO `posts` (`user_id`, `mime`, `imgdata`, `body`) VALUES (?,?,?,?)"
	result, err := db.ExecContext(
		ctx,
		query,
		me.ID,
		mime,
		[]byte{}, // 画像データをこれ以上DBに保存しない
		r.FormValue("body"),
	)
	if err != nil {
		log.Print(err)
		return
	}

	pid, err := result.LastInsertId()
	if err != nil {
		log.Print(err)
		return
	}

	// アップロードされたファイルを配信ディレクトリに書き出し
	// 例: /home/isucon/private_isu/webapp/public/image/〇〇.png
	imgfile := fmt.Sprintf("%s/%d.%s", ImageDir, pid, ext)
	if err := os.WriteFile(imgfile, filedata, 0644); err != nil {
		log.Print("postImage: 画像書き出しに失敗", err, "post_id", pid, "mime", mime, "imgfile", imgfile)
		return
	}

	http.Redirect(w, r, "/posts/"+strconv.FormatInt(pid, 10), http.StatusFound)
}

func postComment(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me := getSessionUser(ctx, r)
	if !isLogin(me) {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}

	if r.FormValue("csrf_token") != getCSRFToken(r) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		return
	}

	postID, err := strconv.Atoi(r.FormValue("post_id"))
	if err != nil {
		log.Print("post_idは整数のみです")
		return
	}

	query := "INSERT INTO `comments` (`post_id`, `user_id`, `comment`, `user_account_name`) VALUES (?,?,?,?)"
	_, err = db.ExecContext(ctx, query, postID, me.ID, r.FormValue("comment"), me.AccountName)
	if err != nil {
		log.Print(err)
		return
	}

	http.Redirect(w, r, fmt.Sprintf("/posts/%d", postID), http.StatusFound)
}

func getAdminBanned(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me := getSessionUser(ctx, r)
	if !isLogin(me) {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	if me.Authority == 0 {
		w.WriteHeader(http.StatusForbidden)
		return
	}

	users := []User{}
	err := db.SelectContext(ctx, &users, "SELECT * FROM `users` WHERE `authority` = 0 AND `del_flg` = 0 ORDER BY `created_at` DESC")
	if err != nil {
		log.Print(err)
		return
	}

	template.Must(template.ParseFiles(
		getTemplPath("layout.html"),
		getTemplPath("banned.html")),
	).Execute(w, struct {
		Users     []User
		Me        User
		CSRFToken string
	}{users, me, getCSRFToken(r)})
}

func postAdminBanned(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	me := getSessionUser(ctx, r)
	if !isLogin(me) {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}

	if me.Authority == 0 {
		w.WriteHeader(http.StatusForbidden)
		return
	}

	if r.FormValue("csrf_token") != getCSRFToken(r) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		return
	}

	query := "UPDATE `users` SET `del_flg` = ? WHERE `id` = ?"

	err := r.ParseForm()
	if err != nil {
		log.Print(err)
		return
	}

	for _, id := range r.Form["uid[]"] {
		db.ExecContext(ctx, query, 1, id)
	}

	http.Redirect(w, r, "/admin/banned", http.StatusFound)
}

func main() {
	setupPyroscope()
	shutdown := initTracer()
	defer shutdown()

	host := os.Getenv("ISUCONP_DB_HOST")
	if host == "" {
		host = "localhost"
	}
	port := os.Getenv("ISUCONP_DB_PORT")
	if port == "" {
		port = "3306"
	}
	_, err := strconv.Atoi(port)
	if err != nil {
		log.Fatalf("Failed to read DB port number from an environment variable ISUCONP_DB_PORT.\nError: %s", err.Error())
	}
	user := os.Getenv("ISUCONP_DB_USER")
	if user == "" {
		user = "root"
	}
	password := os.Getenv("ISUCONP_DB_PASSWORD")
	dbname := os.Getenv("ISUCONP_DB_NAME")
	if dbname == "" {
		dbname = "isuconp"
	}

	dsn := fmt.Sprintf(
		"%s:%s@tcp(%s:%s)/%s?charset=utf8mb4&parseTime=true&loc=Local&interpolateParams=true",
		user,
		password,
		host,
		port,
		dbname,
	)

	rawdb, err := otelsql.Open("mysql", dsn,
		otelsql.WithAttributes(semconv.DBSystemNameMySQL),
		otelsql.WithSpanOptions(otelsql.SpanOptions{
			DisableErrSkip: true, // MySQLだと余計なエラーがrootに出やすいのでSkip(sql.conn.queryが正常なのにエラーとして認識される)
		}),
	)
	if err != nil {
		log.Fatalf("Failed to connect to DB: %s.", err.Error())
	}
	db = sqlx.NewDb(rawdb, "mysql")
	defer db.Close()

	root, err := os.OpenRoot("../public")
	if err != nil {
		log.Fatalf("failed to open root: %v", err)
	}
	defer root.Close()

	r := chi.NewRouter()

	r.Use(otelchi.Middleware("isu-go", otelchi.WithChiRoutes(r)))
	r.Get("/initialize", getInitialize)
	r.Get("/login", getLogin)
	r.Post("/login", postLogin)
	r.Get("/register", getRegister)
	r.Post("/register", postRegister)
	r.Get("/logout", getLogout)
	r.Get("/", getIndex)
	r.Get("/posts", getPosts)
	r.Get("/posts/{id}", getPostsID)
	r.Post("/", postIndex)
	r.Post("/comment", postComment)
	r.Get("/admin/banned", getAdminBanned)
	r.Post("/admin/banned", postAdminBanned)
	r.Get(`/@{accountName:[a-zA-Z]+}`, getAccountName)

	log.Fatal(http.ListenAndServe(":8080", r))
}

// Pyroscope初期化処理
// 再起動時、2秒以内に接続できた場合のみ Pyroscope 開始
func setupPyroscope() {
	serverAddr := "192.168.1.30:4040"
	url := "http://" + serverAddr + "/ready"

	// HTTPでreadyチェック（2秒以内に200なら起動）
	client := http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		log.Printf("[pyroscope] %s に接続できません: %v", url, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Printf("[pyroscope] %s がreadyではありません (status=%d)", url, resp.StatusCode)
		return
	}

	// 接続できた場合のみ Pyroscope 開始
	_, err = pyroscope.Start(pyroscope.Config{
		ApplicationName: "isu-go",
		ServerAddress:   "http://" + serverAddr,
		Logger:          nil, // pyroscope.StandardLogger, // デバッグログを吐く
		ProfileTypes: []pyroscope.ProfileType{
			pyroscope.ProfileCPU,        // cpu: CPUプロファイル(デフォは10秒単位で収集)
			pyroscope.ProfileAllocSpace, // allocs: 割り当てられたメモリサイズ(bytes)
			pyroscope.ProfileInuseSpace, // heap: 現在使用中のメモリサイズ(bytes)
			pyroscope.ProfileGoroutines, // goroutines: ゴルーチンの数
		},
	})
	if err != nil {
		log.Printf("[pyroscope] 初期化失敗: %v", err)
	} else {
		log.Printf("[pyroscope] 初期化成功: %s に継続的プロファイリングをします", serverAddr)
	}
}

var layoutHtmlByteArray = [...][]byte{
	[]byte(`<!DOCTYPE html><html><head><meta charset="utf-8"><title>Iscogram</title><link href="/css/style.css" media="screen" rel="stylesheet" type="text/css"></head><body><div class="container"><div class="header"><div class="isu-title"><h1><a href="/">Iscogram</a></h1></div><div class="isu-header-menu">`),
	[]byte(`<div><a href="/login">ログイン</a></div>`),
	[]byte(`<div><a href="/@`),
	[]byte(`"><span class="isu-account-name">`),
	[]byte(`</span>さん</a></div>`),
	[]byte(`<div><a href="/admin/banned">管理者用ページ</a></div><div><a href="/logout">ログアウト</a></div>`),
	[]byte(`<div><a href="/logout">ログアウト</a></div>`),
	[]byte(`</div></div>`),
	[]byte(`</div><script src="/js/timeago.min.js"></script><script src="/js/main.js"></script></body></html>`),
}

func layoutHtml(w io.Writer, me User, contentBuilder func(b io.Writer)) {
	w.Write(layoutHtmlByteArray[0])
	if me.ID == 0 {
		// 未ログインの場合は、ログインリンク
		w.Write(layoutHtmlByteArray[1])
	} else {
		w.Write(layoutHtmlByteArray[2])
		w.Write([]byte(me.AccountName))
		w.Write(layoutHtmlByteArray[3])
		w.Write([]byte(me.AccountName))
		w.Write(layoutHtmlByteArray[4])
		if me.Authority == 1 {
			// 管理者用ページリンクとログアウトリンク
			w.Write(layoutHtmlByteArray[5])
		} else {
			// ログアウトリンク
			w.Write(layoutHtmlByteArray[6])
		}
	}
	w.Write(layoutHtmlByteArray[7])
	contentBuilder(w)
	w.Write(layoutHtmlByteArray[8])
}

var indexHtmlByteArray = [...][]byte{
	[]byte(`<div class="isu-submit"><form method="post" action="/" enctype="multipart/form-data"><div class="isu-form"><input type="file" name="file" value="file"></div><div class="isu-form"><textarea name="body"></textarea></div><div class="form-submit"><input type="hidden" name="csrf_token" value="`),
	[]byte(`"><input type="submit" name="submit" value="submit"></div>`),
	[]byte(`<div id="notice-message" class="alert alert-danger">`),
	[]byte(`</div>`),
	[]byte(`</form></div>`),
	[]byte(`<div id="isu-post-more"><button id="isu-post-more-btn">もっと見る</button><img class="isu-loading-icon" src="/img/ajax-loader.gif"></div>`),
}

func indexHtml(w io.Writer, posts []Post, csrfToken string, flash string) {
	w.Write(indexHtmlByteArray[0])
	w.Write([]byte(csrfToken))
	w.Write(indexHtmlByteArray[1])
	if flash != "" {
		w.Write(indexHtmlByteArray[2])
		w.Write([]byte(flash))
		w.Write(indexHtmlByteArray[3])
	}
	w.Write(indexHtmlByteArray[4])
	postsHtml(w, posts)
	w.Write(indexHtmlByteArray[5])
}

var postsHtmlByteArray = [...][]byte{
	[]byte(`<div class="isu-post-list">`),
	[]byte(`</div>`),
}

func postsHtml(w io.Writer, posts []Post) {
	w.Write(postsHtmlByteArray[0])
	for _, p := range posts {
		postHtml(w, p)
	}
	w.Write(postsHtmlByteArray[1])
}

var postHtmlByteArray = [...][]byte{
	[]byte(`<div class="isu-post" id="pid_`),
	[]byte(`" data-created-at="`),
	[]byte(`"><div class="isu-post-header"><a href="/@`),
	[]byte(`" class="isu-post-account-name">`),
	[]byte(`</a><a href="/posts/`),
	[]byte(`" class="isu-post-permalink">`),
	[]byte(` "></time></a></div><div class="isu-post-image"><img src="`),
	[]byte(`" class="isu-image"></div><div class="isu-post-text"><a href="/@`),
	[]byte(`" class="isu-post-account-name">`),
	[]byte(`</a>`),
	[]byte(`</div><div class="isu-post-comment"><div class="isu-post-comment-count">comments: <b>`),
	[]byte(`</b></div>`),
	[]byte(`<div class="isu-comment"><a href="/@`),
	[]byte(`" class="isu-comment-account-name">`),
	[]byte(`</a><span class="isu-comment-text">`),
	[]byte(`</span></div>`),
	[]byte(`<div class="isu-comment-form"><form method="post" action="/comment"><input type="text" name="comment"><input type="hidden" name="post_id" value="`),
	[]byte(`"><input type="hidden" name="csrf_token" value="`),
	[]byte(`"><input type="submit" name="submit" value="submit"></form></div></div></div>`),
}

func postHtml(w io.Writer, p Post) {
	createdAt := []byte(p.CreatedAt.Format(time.RFC3339))
	accountName := []byte(p.User.AccountName)

	w.Write(postHtmlByteArray[0])
	w.Write([]byte(strconv.Itoa(p.ID)))
	w.Write(postHtmlByteArray[1])
	w.Write(createdAt)
	w.Write(postHtmlByteArray[2])
	w.Write(accountName)
	w.Write(postHtmlByteArray[3])
	w.Write(accountName)
	w.Write(postHtmlByteArray[4])
	w.Write([]byte(strconv.Itoa(p.ID)))
	w.Write(postHtmlByteArray[5])
	w.Write(createdAt)
	w.Write(postHtmlByteArray[6])
	w.Write([]byte(imageURL(p)))
	w.Write(postHtmlByteArray[7])
	w.Write(accountName)
	w.Write(postHtmlByteArray[8])
	w.Write(accountName)
	w.Write(postHtmlByteArray[9])
	w.Write([]byte(p.Body))
	w.Write(postHtmlByteArray[10])
	w.Write([]byte(strconv.Itoa(p.CommentCount)))
	w.Write(postHtmlByteArray[11])
	for _, c := range p.Comments {
		w.Write(postHtmlByteArray[12])
		w.Write([]byte(strconv.Itoa(c.ID)))
		w.Write(postHtmlByteArray[13])
		w.Write([]byte(c.UserAccountName))
		w.Write(postHtmlByteArray[14])
		w.Write([]byte(c.Comment))
		w.Write(postHtmlByteArray[15])
	}
	w.Write(postHtmlByteArray[16])
	w.Write([]byte(strconv.Itoa(p.ID)))
	w.Write(postHtmlByteArray[17])
	w.Write([]byte(p.CSRFToken))
	w.Write(postHtmlByteArray[18])
}

var userHtmlByteArray = [...][]byte{
	[]byte(`<div class="isu-user"><div><span class="isu-user-account-name">`),
	[]byte(`さん</span>のページ</div><div>投稿数 <span class="isu-post-count">`),
	[]byte(`</span></div><div>コメント数 <span class="isu-comment-count">`),
	[]byte(`</span></div><div>被コメント数 <span class="isu-commented-count">`),
	[]byte(`</span></div></div>`),
}

func userHtml(w io.Writer, posts []Post, u User, postCount int, commentsCount int, commentedCount int) {
	w.Write(userHtmlByteArray[0])
	w.Write([]byte(u.AccountName))
	w.Write(userHtmlByteArray[1])
	w.Write([]byte(strconv.Itoa(postCount)))
	w.Write(userHtmlByteArray[2])
	w.Write([]byte(strconv.Itoa(commentsCount)))
	w.Write(userHtmlByteArray[3])
	w.Write([]byte(strconv.Itoa(commentedCount)))
	w.Write(userHtmlByteArray[4])

	postsHtml(w, posts)
}
