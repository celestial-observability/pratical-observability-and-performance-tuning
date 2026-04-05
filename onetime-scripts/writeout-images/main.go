package main

import (
	"bufio"
	"fmt"
	"log/slog"
	"os"
	"sync"

	_ "github.com/go-sql-driver/mysql"
	"github.com/jmoiron/sqlx"
)

type Post struct {
	ID      int    `db:"id"`
	Mime    string `db:"mime"`
	Imgdata []byte `db:"imgdata"`
}

func getExtension(mime string) string {
	switch mime {
	case "image/jpeg":
		return "jpg"
	case "image/png":
		return "png"
	case "image/gif":
		return "gif"
	default:
		return "jpg"
	}
}

// 画像ファイルが存在すればスキップ。並列化・バッファ付き書き込み採用。
func writeImages() {
	imgPath := "/home/isucon/private_isu/webapp/public/image"

	// mkdir -p 相当の処理
	if err := os.MkdirAll(imgPath, 0755); err != nil {
		slog.Error("MkdirAllでエラー", err)
		return
	}

	db, err := sqlx.Open(
		"mysql",
		"isuconp:isuconp@tcp(localhost:3306)/isuconp?charset=utf8mb4&parseTime=true&loc=Local&interpolateParams=true",
	)
	if err != nil {
		slog.Error("sqlx.Openでエラー", err)
		return
	}
	defer db.Close()

	offset := 0
	limit := 200 // まとめて取得（バッチを大きめに）

	// 画像チャネルとworker
	images := make(chan Post, limit)
	var wg sync.WaitGroup
	workers := 8 // 並列worker数（サーバリソースに応じて調整）

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for post := range images {
				filename := fmt.Sprintf("%s/%d.%s", imgPath, post.ID, getExtension(post.Mime))
				if _, err := os.Stat(filename); err == nil {
					slog.Info("既にあるため画像書き出しスキップ", "filename", filename)
					continue
				}
				f, err := os.Create(filename)
				if err != nil {
					slog.Error("os.Createでエラー", err, "filename", filename)
					continue
				}
				w := bufio.NewWriter(f)
				_, err = w.Write(post.Imgdata)
				if err != nil {
					slog.Error("bufio.Writeでエラー", err, "filename", filename)
					f.Close()
					continue
				}
				w.Flush()
				f.Close()
				slog.Info("画像書き出し成功", "filename", filename)
			}
		}()
	}

	for {
		posts := []Post{}
		err := db.Select(&posts, "SELECT id, mime, imgdata FROM posts WHERE id <= 10000 ORDER BY id ASC LIMIT ? OFFSET ?", limit, offset)
		if err != nil {
			slog.Error("db.Selectでエラー", err, "limit", limit, "offset", offset)
			break
		}
		if len(posts) == 0 {
			break
		}
		for _, post := range posts {
			images <- post // チャネルに流すことでworkerに分散
		}
		offset += limit
	}

	close(images)
	wg.Wait()
}

func main() {
	fmt.Println("画像の書き出し")
	writeImages()
}
