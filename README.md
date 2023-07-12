## :lizard: :moon: **zig luajit**

[![CI][ci-shield]][ci-url]
[![License][license-shield]][license-url]

### Zig build of the [LuaJIT repository](https://github.com/LuaJIT/LuaJIT) created by [Mike Pall](https://github.com/MikePall).

#### :rocket: Usage

1. Add `luajit` as a dependency in your `build.zig.zon`.

    <details>

    <summary><code>build.zig.zon</code> example</summary>

    ```zig
    .{
        .name = "<name_of_your_package>",
        .version = "<version_of_your_package>",
        .dependencies = .{
            .luajit = .{
                .url = "https://github.com/tensorush/zig-luajit/archive/<git_tag_or_commit_hash>.tar.gz",
                .hash = "<package_hash>",
            },
        },
    }
    ```

    Set `<package_hash>` to `12200000000000000000000000000000000000000000000000000000000000000000`, and Zig will provide the correct found value in an error message.

    </details>

2. Add `luajit` as a module in your `build.zig`.

    <details>

    <summary><code>build.zig</code> example</summary>

    ```zig
    const luajit = b.dependency("luajit", .{});
    exe.addModule("luajit", luajit.module("luajit"));
    ```

    </details>

<!-- MARKDOWN LINKS -->

[ci-shield]: https://img.shields.io/github/actions/workflow/status/tensorush/zig-luajit/ci.yaml?branch=main&style=for-the-badge&logo=github&label=CI&labelColor=black
[ci-url]: https://github.com/tensorush/zig-luajit/blob/main/.github/workflows/ci.yaml
[license-shield]: https://img.shields.io/github/license/tensorush/zig-luajit.svg?style=for-the-badge&labelColor=black
[license-url]: https://github.com/tensorush/zig-luajit/blob/main/LICENSE.md
