把整合包 mods 文件夹里的 irons_spellbooks-*.jar 复制到这个目录，即可离线编译。

- 文件名要匹配 irons_spellbooks*.jar（例如 irons_spellbooks-1.21.1-3.16.3.jar）
- 放进来之后，build.gradle 会自动优先用它，而不再去 api.modrinth.com 拉依赖
- 这个目录里的 jar 只用于编译（compileOnly），不会被打进本模组的产物里
