#!/usr/bin/env coffee
#
# Copyright 2013 Artillery Games, Inc.
# Licensed under the MIT license.
#
# Author: Ian Langworth
#
# Inspired strongly by
# https://github.com/jaredhanson/passport-github/blob/master/examples/login/app.js

GitHubAPI = require 'github'
GitHubStrategy = require('passport-github').Strategy
async = require 'async'
express = require 'express'
fs = require 'fs'
http = require 'http'
md5 = require 'MD5'
moment = require 'moment'
optimist = require 'optimist'
passport = require 'passport'
path = require 'path'
stylus = require 'stylus'

argv = optimist
  .usage('Usage: $0 settings.json')
  .options('-h', alias: 'host', default: 'localhost')
  .options('-p', alias: 'port', default: 8000)
  .demand(1)
  .argv

settings = JSON.parse fs.readFileSync argv._[0]

requireEnv = (name) ->
  value = process.env[name]
  if not value?
    console.error "Need to specify #{ name } env var"
    process.exit(1)
  return value

# Map of GitHub username -> Gravatar URL.
# The URL can be null for incorrect github usernames
usernameToAvatar = {}

# -------------------------------------------------------------------------
# GITHUB INITIALIZATION
# -------------------------------------------------------------------------

settings.github = {
  user: requireEnv "GITHUB_USER"
  repo: requireEnv "GITHUB_REPO"
  clientID: requireEnv "GITHUB_CLIENT_ID"
  clientSecret: requireEnv "GITHUB_CLIENT_SECRET"
  callbackURL: requireEnv "GITHUB_CALLBACK_URL"
}

passport.use new GitHubStrategy({
  clientID: settings.github.clientID
  clientSecret: settings.github.clientSecret
  callbackURL: settings.github.callbackURL
}, (accessToken, refreshToken, profile, done) ->
  process.nextTick ->
    return done null, { profile: profile, accessToken: accessToken }
)

passport.serializeUser (user, done) -> done null, user
passport.deserializeUser (user, done) -> done null, user

# -------------------------------------------------------------------------
# EXPRESS INITIALIZATION
# -------------------------------------------------------------------------

app = express()

app.configure ->
  app.set 'port', argv.port
  app.set 'views', "#{ __dirname }/views"
  app.set 'view engine', 'hjs'
  app.use express.favicon()
  app.use express.logger 'dev'
  app.use express.bodyParser()
  app.use express.methodOverride()
  app.use express.cookieParser md5(Math.random())
  app.use express.session secret: md5(Math.random())
  app.use passport.initialize()
  app.use passport.session()
  app.use app.router
  app.use stylus.middleware "#{ __dirname }/public"
  app.use express.static path.join "#{ __dirname }/public"

app.configure 'development', ->
  app.use express.errorHandler()

# -------------------------------------------------------------------------
# AUTHENTICATION HANDLERS
# -------------------------------------------------------------------------

app.get '/auth/github', passport.authenticate 'github', scope: 'repo'

app.get '/auth/github/callback',
  passport.authenticate('github', failureRedirect: '/error'),
  (req, res) ->
    res.redirect '/'

app.get '/logout', (req, res) ->
  req.logout()
  res.redirect '/'

ensureAuthenticated = (req, res, next) ->
  if req.isAuthenticated()
    return next()
  else
    res.redirect '/auth/github'

# -------------------------------------------------------------------------
# DASHBOARD
# -------------------------------------------------------------------------

app.get '/', ensureAuthenticated, (req, res) ->
  github = new GitHubAPI(version: '3.0.0')
  github.authenticate type: 'oauth', token: req.user.accessToken

  username = req.user.profile.username

  async.waterfall [

    (cb) ->
      github.pullRequests.getAll {
        user: settings.github.user
        repo: settings.github.repo
      }, cb

    (pulls, cb) ->
      iterator = (pull, pullCb) ->

        async.parallel [

          (cb2) ->
            github.statuses.get {
              user: settings.github.user
              repo: settings.github.repo
              sha: pull.head.sha
            }, cb2

          (cb2) ->
            github.gitdata.getCommit {
              user: settings.github.user
              repo: settings.github.repo
              sha: pull.head.sha
            }, cb2

          (cb2) ->
            github.pullRequests.getComments {
              user: settings.github.user
              repo: settings.github.repo
              number: pull.number
            }, cb2

          (cb2) ->
            github.issues.getComments {
              user: settings.github.user
              repo: settings.github.repo
              number: pull.number
            }, cb2

        ], (err, results) ->
          return pullCb err if err

          # Grab build status codes (if they exist).
          statuses = results[0]
          if statuses.length > 0
            status = statuses[0].state
            for config in settings.buildStatuses
              if new RegExp(config.regex, 'i').test status
                pull.buildStatusClass = config.class
                pull.buildStatus = config.title
                break
          if not pull.buildStatus
            pull.buildStatusClass = 'ignore'
            pull.buildStatus = 'n/a'

          # Get head commit for this pull.
          head = results[1]

          # Combine issue comments and pull comments, then sort.
          comments = results[2].concat results[3]

          # Convert to moment for sortability.
          for comment in comments
            comment.updated_at = moment comment.updated_at

          comments.sort (a, b) ->
            return if a.updated_at.isBefore b.updated_at then -1 else 1

          # Record number of comments.
          pull.num_comments = comments.length

          # Show relative time for last commit or comment, whichever is more recent.
          pull.last_user = pull.user.login
          pull.last_update = moment head.committer.date

          if comments.length > 0
            lastComment = comments[comments.length - 1]
            if lastComment.updated_at.isAfter pull.last_update
              pull.last_user = lastComment.user.login
              pull.last_update = lastComment.updated_at

          pull.last_update_string = pull.last_update.fromNow()

          # Pull names from comments.
          reviewers = {}

          # Extract reviewers from pull title.
          if match = pull.title.match /^([\w\/]+): /
            # Strip the names out of the title.
            pull.title = pull.title.substr match[0].length

            # Convert title to reviewers.
            names = (n.toLowerCase() for n in match[1].split /\//)

            # Convert "IAN/MARK" to ['statico', 'mlogan']
            for name in names
              if name in ['everyone', 'all']
                # Add all reviewers.
                reviewers[name] = true for _, name of settings.reviewers
              else if name of settings.reviewers
                reviewers[settings.reviewers[name]] = true
              else
                reviewers[name] = true

          # Is this pull a proposal?
          if 'proposal' of reviewers
            pull.class = 'info'
            pull.title = "PROPOSAL: #{ pull.title }"
            delete reviewers.proposal

          # Check for my username in submitter or reviewers.
          if username == pull.user.login or username of reviewers
            pull.class = 'warning'

          # Check for my username in any comments.
          if username in (c.user.login for c in comments)
            pull.class = 'warning'

          # Is this pull a Work In Progress?
          if 'wip' of reviewers
            pull.class = 'ignore'
            pull.title = "WIP: #{ pull.title }"
            delete reviewers.wip

          # Default status of New.
          pull.reviewStatusClass = 'info'
          pull.reviewStatus = 'New'

          # Unless there are comments.
          if comments.length
            pull.reviewStatusClass = 'default'
            pull.reviewStatus = 'Discussing'

          # Or there is e.g. GLHF in last comment.
          if comments.length > 0
            body = comments[comments.length - 1].body
            for config in settings.reviewStatuses
              if new RegExp(config.regex, 'i').test body
                pull.reviewStatusClass = config.class
                pull.reviewStatus = config.title
                break

          # Add reviewers list to pull object.
          pull.reviewers = (k for k, v of reviewers)

          pullCb()

      async.forEach pulls, iterator, (err) ->
        cb err, pulls

    # Replace submitter and reviewers with { username: ..., avatar: ... } objects.
    (pulls, cb) ->

      # Collect all names of reviewers.
      usernames = {}
      for pull in pulls
        usernames[pull.user.login] = true
        for name in pull.reviewers
          usernames[name] = true

      # Make sure we have avatars for everybody.
      iterator = (username, cb2) ->
        if username of usernameToAvatar
          return cb2()

        github.user.getFrom {
          user: username
        }, (err, res) ->
          return cb2 err if err
          usernameToAvatar[username] = res.avatar_url
          cb2()

      # When done, replace properties with objects.
      async.forEach Object.keys(usernames), iterator, (err) ->
        for pull in pulls
          pull.submitter =
            username: pull.user.login
            avatar: usernameToAvatar[pull.user.login]

          if pull.last_user
            pull.last_user =
              username: pull.last_user
              avatar: usernameToAvatar[pull.last_user]

          obj = []
          for name in pull.reviewers
            obj.push
              username: name
              avatar: usernameToAvatar[name]
          pull.reviewers = obj

        cb err, pulls

    # Sort the pulls based on update time.
    (pulls, cb) ->
      pulls.sort (a, b) ->
        if a.last_update.isBefore b.last_update then 1 else -1

      cb null, pulls

  ], (err, pulls) ->
    if err
      res.send """
        <html>
          <head>
            <meta http-equiv="refresh" content="3"/>
          <head>
          <body>
            Error: <code>#{ require('util').inspect err }</code>
            <br/>
            Refreshing in a few seconds...
          </body>
        </html>
      """
    else
      res.render 'index',
        settings: settings
        profile: req.user.profile
        pulls: pulls

# -------------------------------------------------------------------------
# SERVER STARTUP
# -------------------------------------------------------------------------

http.createServer(app).listen argv.port, argv.host, ->
  console.log "Pull Request Viewer listening on port http://#{ argv.host }:#{ argv.port }"

