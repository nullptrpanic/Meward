# Publishing the support site

Edit the public support and privacy pages in `website/` on `dev`. Open a pull request from `dev` to `master` to publish. The stable `master` branch receives changes only through merges.

In the repository’s [Pages settings](https://github.com/nullptrpanic/Meward/settings/pages), set **Build and deployment → Source** to **GitHub Actions**. The [Deploy website workflow](../.github/workflows/pages.yml) publishes the contents of `website/` when changes to that directory or the workflow are merged into `master`. To repeat a deployment, run the workflow on `master`.

After deployment, check the [support page](https://nullptrpanic.github.io/Meward/) and [privacy policy](https://nullptrpanic.github.io/Meward/privacy/). Both accept `?lang=en` and `?lang=zh`.
