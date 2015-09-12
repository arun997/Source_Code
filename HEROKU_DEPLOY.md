# Deploy To Heroku
- `git clone git@github.com:arun997/Source_Code.git`
- Install hero cli https://devcenter.heroku.com/articles/getting-started-with-ruby#set-up
- `heroku create your-apps-name --addons heroku-postgresql`
- `git push heroku master`
- `heroku config:set SECRET_TOKEN=your_super_secret_token`
- `heroku run rake db:migrate`
- `heroku run rake db:seed`

