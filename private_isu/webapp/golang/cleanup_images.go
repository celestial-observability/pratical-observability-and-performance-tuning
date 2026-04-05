package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
)

var ImageDir = "/home/isucon/private_isu/webapp/public/image"

// ImageDir以下の画像をすべて削除する
// ImageDir自体は削除しない
func cleanupImages() {
	entries, err := os.ReadDir(ImageDir)
	if err != nil {
		fmt.Println("読み込みに失敗", err)
		panic(err)
	}
	re := regexp.MustCompile(`^(\d+)\.\w+$`)
	for _, entry := range entries {
		path := filepath.Join(ImageDir, entry.Name())
		if entry.IsDir() {
			// サブディレクトリをまるごと削除
			err = os.RemoveAll(path)
		} else {
			// ファイル名判定の追加
			base := entry.Name()
			if m := re.FindStringSubmatch(base); m != nil {
				n, err := strconv.Atoi(m[1])
				if err == nil && 1 <= n && n <= 10000 {
					// 1〜10000.*のファイルはスキップ
					continue
				}
			}
			// ファイルの削除
			err = os.Remove(path)
		}
		if err != nil {
			fmt.Println("ファイル削除に失敗:", path, "err: ", err)
			panic(err)
		}
	}
}
