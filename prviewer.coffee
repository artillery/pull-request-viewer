#!/usr/bin/env coffee
#
# Copyright 2013 Artillery Games, Inc.
# Licensed under the MIT license.
#
# Author: Ian Langworth
#
# Inspired strongly by
# https://github.com/jaredhanson/passport-github/blob/master/examples/login/app.js

GitHubStrategy = require('passport-github').Strategy
Promise = require 'promise'
express = require 'express'
fs = require 'fs'
ghrequest = require 'ghrequest'
http = require 'http'
humanize = require 'humanize-plus'
md5 = require 'md5'
moment = require 'moment'
optimist = require 'optimist'
passport = require 'passport'
pathlib = require 'path'
stylus = require 'stylus'

argv = optimist
  .usage('Usage: $0 settings.json')
  .demand(1)
  .argv

settings = JSON.parse fs.readFileSync argv._[0]

# Copy env from ./env
env = pathlib.join __dirname, '.env'
if fs.existsSync env
  lines = fs.readFileSync(env, 'utf8').split '\n'
  for line in lines
    continue unless line
    [key, value] = line.split '='
    unless key and value
      console.warn "Ignoring env line: '#{ line }'"
      continue
    process.env[key] = value
    console.log "Read from #{ env }: #{ key }=#{ value }"

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
  console.assert user and repo, "Bad user/repo: '#{ spec }'"
  settings.github.repos.push { user: user, repo: repo }
console.log "Repositories:", JSON.stringify(settings.github.repos, null, '  ')

settings.github.forcedReviewers = do ->
  obj = {}
  if process.env.GITHUB_FORCE_REVIEWERS
    for spec in process.env.GITHUB_FORCE_REVIEWERS.split(',')
      match = spec.match /^(.+)\/(.+):(.+)$/
      if not match
        console.error "Incorrect value in GITHUB_FORCE_REVIEWERS: #{ spec }"
        continue
      [_, user, repo, reviewer] = match
      obj[user] ?= {}
      obj[user][repo] ?= []
      obj[user][repo].push reviewer
  console.log "Forced reviewers:", JSON.stringify(obj, null, '  ')
  return obj

settings.reviewers ?= do -> # `?=` for backward-compatibility
  obj = {}
  if process.env.GITHUB_USERNAME_ALIASES
    for spec in process.env.GITHUB_USERNAME_ALIASES.split(',')
      [alias, username] = spec.split ':'
      obj[alias] = username
  console.log "Username aliases:", JSON.stringify(obj, null, '  ')
  return obj

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

callAPI = (token, url, params = {}) ->
  return new Promise((resolve, reject) ->
    ghrequest {
      url: url
      qs: params
      headers:
        'Authorization': "token #{ token }"
        'User-Agent': 'github.com/artillery/pull-request-viewer'
    }, (err, res, body) ->
      if err
        reject err
      else
        body.meta ?= {}
        body.meta['x-ratelimit-remaining'] = res.headers['x-ratelimit-remaining']
        resolve body
  )

getAllPullRequests = (token, user, repo) ->
  return callAPI token, "/repos/#{ user }/#{ repo }/pulls"

getBuildStatuses = (token, user, repo, sha) ->
  return callAPI token, "/repos/#{ user }/#{ repo }/commits/#{ sha }/status"

getCommit = (token, user, repo, sha) ->
  return callAPI token, "/repos/#{ user }/#{ repo }/git/commits/#{ sha }"

getPullComments = (token, user, repo, number) ->
  return callAPI token, "/repos/#{ user }/#{ repo }/pulls/#{ number }/comments"

getIssueComments = (token, user, repo, number) ->
  return callAPI token, "/repos/#{ user }/#{ repo }/issues/#{ number }/comments"

getFrom = (token, user) ->
  return callAPI token, "/users/#{ user }"

# -------------------------------------------------------------------------
# EXPRESS INITIALIZATION
# -------------------------------------------------------------------------

app = express()

app.configure ->
  app.set 'port', port
  app.set 'views', "#{ __dirname }/views"
  app.set 'view engine', 'jade'
  app.use express.favicon()
  app.use express.logger 'dev'
  app.use express.bodyParser()
  app.use express.methodOverride()
  app.use express.cookieParser md5(Math.random())
  app.use express.session secret: md5(Math.random())
  app.use passport.initialize()
  app.use passport.session()
  app.use (req, res, next) ->
    res.locals.humanize = humanize
    next()
  app.use app.router
  app.use stylus.middleware "#{ __dirname }/public"
  app.use express.static pathlib.join "#{ __dirname }/public"

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

  if req.isAuthenticated()
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
      return Promise.resolve(pulls)

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
            pull.buildStatusUrl = status.target_url
            break
      if not pull.buildStatus
        pull.buildStatusClass = 'muted'
        pull.buildStatus = 'n/a'
        pull.buildStatusUrl = null

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
      pull.last_comment = lastComment
      pull.last_update_string = pull.last_update.fromNow()

      # Pull names from comments.
      reviewers = {}

      # Add reviewers from GITHUB_FORCE_REVIEWERS, if any.
      if names = settings.github.forcedReviewers[ghUser]?[ghRepo]
        console.log "Forcing #{ names } as reviewers for pull #{ pull.id }"
        for name in names
          reviewers[name] = true

      # Extract reviewers from pull title.
      pull.displayTitle = pull.title
      if match = pull.title.match /^([\w\/]+): /
        # Strip the names out of the title.
        pull.displayTitle = pull.title.substr match[0].length

        # Convert title to reviewers.
        names = (n.toLowerCase() for n in match[1].split /\//)

        # Convert "IAN/MARK" to ['statico', 'mlogan']
        pull.anyReviewer = false
        for name in names
          if name in ['everyone', 'all', 'anyone', 'someone', 'anybody']
            # Add all reviewers.
            reviewers[name] = true for _, name of settings.reviewers
            pull.anyReviewer = true
          else if name of settings.reviewers
            reviewers[settings.reviewers[name]] = true
          else
            reviewers[name] = true

      # Is this pull a proposal?
      if 'proposal' of reviewers
        pull.class = 'info'
        pull.displayTitle = "PROPOSAL: #{ pull.displayTitle }"
        delete reviewers.proposal

      # Extract tags from pull request title.
      pull.tags = []
      pull.displayTitle = pull.displayTitle.replace /\s*\[([^\]]+)\]/g, (_, tag) ->
        pull.tags.push tag
        return ''

      # Check for my username in submitter or reviewers.
      if myUsername is pull.user.login or myUsername of reviewers
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
          return Promise.resolve(obj)

      promises = []

      promises.push getUserObj(pull.user.login).then (obj) -> pull.submitter = obj
      if pull.last_user
        promises.push getUserObj(pull.last_user).then (obj) -> pull.last_user = obj

      for username in pull.reviewers
        promises.push getUserObj(username).then (obj) -> pull.reviewers.push obj
      pull.reviewers = [] # Above callbacks happen after this.

      onResolved = -> return Promise.resolve pull
      onRejected = (err) -> throw err
      return Promise.all(promises).then(onResolved, onRejected)

  # Annotate a bunch of pulls.
  annotatePulls = (pulls) ->
    return Promise.all(annotateOnePull(pull) for pull in pulls)

  # Hide old pulls that nobody wants to close.
  hideOldPulls = (pulls) ->
    lastMonth = moment().subtract(1, 'month')
    pulls = (p for p in pulls when p.last_update.isAfter lastMonth)
    return Promise.resolve pulls

  # Sort the pull requests in our own special way.
  sortPulls = (pulls) ->
    pulls.sort (a, b) ->
      if not a.last_update then return 1
      if not b.last_update then return -1
      if a.last_update.isBefore b.last_update then 1 else -1
    return Promise.resolve(pulls)

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
        countMine: (true for p in pulls when p.class == 'warning').length
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

  Promise.resolve()
    .then(fetchAllPulls)
    .then(annotatePulls)
    .then(hideOldPulls)
    .then(sortPulls)
    .then(renderDashboard)
    .catch(renderError)

# -------------------------------------------------------------------------
# SERVER STARTUP
# -------------------------------------------------------------------------

http.createServer(app).listen port, ->
  console.log "Pull Request Viewer listening on http://localhost:#{ port }"

