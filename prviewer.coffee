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
Promise = require 'promise'
express = require 'express'
fs = require 'fs'
http = require 'http'
md5 = require 'MD5'
memoize = require 'memoizee'
moment = require 'moment'
optimist = require 'optimist'
passport = require 'passport'
path = require 'path'
stylus = require 'stylus'

argv = optimist
  .usage('Usage: $0 settings.json')
  .demand(1)
  .argv

settings = JSON.parse fs.readFileSync argv._[0]

port = process.env.PORT or 8000

requireEnv = (name) ->
  value = process.env[name]
  if not value?
    console.error "Need to specify #{ name } env var"
    process.exit(1)
  return value

# -------------------------------------------------------------------------
# GITHUB INITIALIZATION
# -------------------------------------------------------------------------

settings.github = {
  clientID: requireEnv "GITHUB_CLIENT_ID"
  clientSecret: requireEnv "GITHUB_CLIENT_SECRET"
  callbackURL: requireEnv "GITHUB_CALLBACK_URL"
  repos: []
}

for spec in requireEnv('GITHUB_REPOS').split ','
  [user, repo] = spec.split '/'
  settings.github.repos.push { user: user, repo: repo }

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
# GITHUB HELPERS
# -------------------------------------------------------------------------

CACHE_MS = 1 * 60 * 1000

getGitHubHelper = (token) ->
  github = new GitHubAPI(version: '3.0.0', debug: process.env.DEBUG)
  github.authenticate type: 'oauth', token: token
  return github
getGitHubHelper = memoize getGitHubHelper # Cache forever.

getAllPullRequests = (token, user, repo, cb) ->
  github = getGitHubHelper token
  return Promise.denodeify(github.pullRequests.getAll)({ user: user, repo: repo })
getAllPullRequests = memoize getAllPullRequests, maxAge: CACHE_MS

getBuildStatuses = (token, user, repo, sha, cb) ->
  github = getGitHubHelper token
  return Promise.denodeify(github.statuses.get)({ user: user, repo: repo, sha: sha })
getBuildStatuses = memoize getBuildStatuses, maxAge: CACHE_MS

getCommit = (token, user, repo, sha, cb) ->
  github = getGitHubHelper token
  return Promise.denodeify(github.gitdata.getCommit)({ user: user, repo: repo, sha: sha })
getCommit = memoize getCommit, maxAge: CACHE_MS

getPullComments = (token, user, repo, number, cb) ->
  github = getGitHubHelper token
  return Promise.denodeify(github.pullRequests.getComments)({ user: user, repo: repo, number: number })
getPullComments = memoize getPullComments, maxAge: CACHE_MS

getIssueComments = (token, user, repo, number, cb) ->
  github = getGitHubHelper token
  return Promise.denodeify(github.issues.getComments)({ user: user, repo: repo, number: number })
getIssueComments = memoize getIssueComments, maxAge: CACHE_MS

getFrom = (token, username, cb) ->
  github = getGitHubHelper token
  return Promise.denodeify(github.user.getFrom)({ user: username })
getFrom = memoize getFrom # Cache forever.

# -------------------------------------------------------------------------
# EXPRESS INITIALIZATION
# -------------------------------------------------------------------------

app = express()

app.configure ->
  app.set 'port', port
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
  # Force HTTPS - https://devcenter.heroku.com/articles/ssl
  proto = req.headers['x-forwarded-proto']
  if proto? and proto != 'https'
    res.redirect "https://#{req.headers["host"]}#{req.url}"
    return

  if req.param('token') == requireEnv 'DASHBOARD_TOKEN'
    return next()
  else if req.isAuthenticated()
    return next()
  else
    res.redirect '/auth/github'

# -------------------------------------------------------------------------
# DASHBOARD
# -------------------------------------------------------------------------

# Save the token of whoever logged in last so we can refresh the dashboard.
lastUsedToken = null

app.get '/', ensureAuthenticated, (req, res) ->
  myUsername = req.user?.profile?.username

  token = req.user?.accessToken or lastUsedToken
  if not token
    throw new Error("No access token available")
  if req.user?.accessToken
    lastUsedToken = req.user?.accessToken

  rateLimitRemaining = Infinity

  # -------------------------------------------------------------------------

  # Get all of the pull requests from GitHub.
  fetchAllPulls = ->
    repos = settings.github.repos
    promises = (getAllPullRequests(token, spec.user, spec.repo) for spec in repos)
    return Promise.all(promises).then (listOfPulls) ->
      # Turn the list of lists into a single list with every pull request.
      pulls = []
      for list in listOfPulls
        pulls = pulls.concat list
      return Promise.from(pulls)

  # Add all of the fun information to a pull request.
  annotateOnePull = (pull) ->
    ghUser = pull.base.user.login
    ghRepo = pull.base.repo.name
    return Promise.all([
      getBuildStatuses token, ghUser, ghRepo, pull.head.sha
      getCommit token, ghUser, ghRepo, pull.head.sha
      getPullComments token, ghUser, ghRepo, pull.number
      getIssueComments token, ghUser, ghRepo, pull.number
    ]).then (results) ->
      [statuses, head, pullComments, issueComments] = results

      # Grab build status codes (if they exist).
      if statuses.length > 0
        status = statuses.reduce(
          (prev, curr) -> return if curr.updated_at > prev.updated_at then curr else prev,
          statuses[0])
        for config in settings.buildStatuses
          if new RegExp(config.regex, 'i').test status.state
            pull.buildStatusClass = config.class
            pull.buildStatus = config.title
            break
      if not pull.buildStatus
        pull.buildStatusClass = 'ignore'
        pull.buildStatus = 'n/a'

      # Get rate limit remaining.
      for result in results
        value = result.meta?['x-ratelimit-remaining']
        if value
          rateLimitRemaining = Math.min(rateLimitRemaining, value)

      # Combine issue comments and pull comments, then sort.
      comments = pullComments.concat issueComments
      for comment in comments
        comment.updated_at = moment comment.updated_at
      comments.sort (a, b) ->
        return if a.updated_at.isBefore b.updated_at then -1 else 1

      # Record number of comments.
      pull.num_comments = comments.length

      # Show relative time for last commit or comment, whichever is more recent.
      pull.last_user = pull.user.login
      pull.last_update = moment head.committer.date

      # Get last user that interacted with the PR and what they said.
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
        pull.displayTitle = pull.title.substr match[0].length

        # Convert title to reviewers.
        names = (n.toLowerCase() for n in match[1].split /\//)

        # Convert "IAN/MARK" to ['statico', 'mlogan']
        for name in names
          if name in ['everyone', 'all', 'anyone', 'someone', 'anybody']
            # Add all reviewers.
            reviewers[name] = true for _, name of settings.reviewers
          else if name of settings.reviewers
            reviewers[settings.reviewers[name]] = true
          else
            reviewers[name] = true

      # Is this pull a proposal?
      if 'proposal' of reviewers
        pull.class = 'info'
        pull.displayTitle = "PROPOSAL: #{ pull.displayTitle }"
        delete reviewers.proposal

      # Check for my username in submitter or reviewers.
      if myUsername == pull.user.login or username of reviewers
        pull.class = 'warning'

      # Check for my username in any comments.
      if myUsername in (c.user.login for c in comments)
        pull.class = 'warning'

      # Is this pull a Work In Progress?
      if 'wip' of reviewers
        pull.class = 'ignore'
        pull.displayTitle = "WIP: #{ pull.displayTitle }"
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

      # Replace usernames with { username, avatar } objects for the template.
      getUserObj = (username) ->
        return getFrom(token, username).then (user) ->
          obj = { username: username, avatar: user.avatar_url }
          return Promise.from(obj)

      promises = []

      promises.push getUserObj(pull.user.login).then (obj) -> pull.submitter = obj
      if pull.last_user
        promises.push getUserObj(pull.last_user).then (obj) -> pull.last_user = obj

      for username in pull.reviewers
        promises.push getUserObj(username).then (obj) -> pull.reviewers.push obj
      pull.reviewers = [] # Above callbacks happen after this.

      onResolved = -> return Promise.from pull
      onRejected = (err) -> throw err
      return Promise.all(promises).then(onResolved, onRejected)

  # Annotate a bunch of pulls.
  annotatePulls = (pulls) ->
    return Promise.all(annotateOnePull(pull) for pull in pulls)

  # Sort the pull requests in our own special way.
  sortPulls = (pulls) ->
    pulls.sort (a, b) ->
      if not a.last_update then return 1
      if not b.last_update then return -1
      if a.last_update.isBefore b.last_update then 1 else -1
    return Promise.from(pulls)

  # Render the dashboard, either as HTML or as JSON for the Geckoboard.
  renderDashboard = (pulls) ->
    if req.param('dashboard')
      # Return JSON in Geckoboard format.

      labelsToCSSColor =
        default: 'grey'
        primary: 'darkblue'
        success: 'darkgreen'
        info: 'darkcyan'
        warning: 'darkorange'
        danger: 'darkred'

      items = []
      for pull in pulls
        continue if pull.class == 'ignore'
        items.push
          label:
            name: pull.reviewStatus
            color: labelsToCSSColor[pull.reviewStatusClass]
          title:
            text: "##{ pull.number } - #{ pull.displayTitle }"
          description: "by #{ pull.submitter.username } - for #{ (r.username for r in pull.reviewers).join ', ' }"
      res.json items

    else
      res.render 'index',
        settings: settings
        profile: req.user.profile
        pulls: pulls
        rateLimitRemaining: rateLimitRemaining

  # For errors, show a page that auto-refreshes. (Sometimes the GitHub API freaks out.)
  renderError = (err) ->
    res.send 500, """
      <html>
        <head>
          <meta http-equiv="refresh" content="30"/>
        <head>
        <body>
          Error: <code>#{ require('util').inspect err }</code>
          <br/>
          Stack trace, if any:
          <br/>
          <pre><code>#{ err.stack }</code></pre>
          <br/>
          Refreshing in a few seconds...
        </body>
      </html>
    """

  fetchAllPulls()
    .then(annotatePulls)
    .then(sortPulls)
    .then(renderDashboard)
    .then(null, renderError)
    .done()

# -------------------------------------------------------------------------
# SERVER STARTUP
# -------------------------------------------------------------------------

http.createServer(app).listen port, ->
  console.log "Pull Request Viewer listening on http://localhost:#{ port }"

