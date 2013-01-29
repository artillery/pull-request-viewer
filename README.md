# Pull Request Viewer

This application provides an alternative interface to viewing pull requests on GitHub. It sorts, highlights and categorizes pull requests based on our workflow.

<img src="http://i.imgur.com/1XaEA.png"/>

## Notable features

* Uses GitHub for authentication
* Highlights PRs involving you
* Parses the last comment of a PR to set a status label
* If PR titles begin with reviewer names `foo:` or `foo/bar/baz:`, the names will be converted to GitHub usernames per the settings file
* Lists everyone involved in commenting in a PR
* Shows and sorts by last update time
* Shows the source branch name
* Shows CI build status

## Getting started

    $ git clone git://github.com/artillery/pull-request-viewer.git
    $ cd pull-request-viewer
    $ npm install
    $ npm install -g coffee-script nodemon
    $ vim settings.json # see below
    $ nodemon prviewer.coffee settings.json
    
## Example settings.json

    {
      "github": {
        "user": "artillery",
        "repo": "superstuff",
        "clientID": "<see Applications in GitHub settings>",
        "clientSecret": "<see Applications in GitHub settings>",
        "callbackURL": "<see Applications in GitHub settings>"
      },
      "buildStatuses": [
	    { "title": "Success", "class": "success", "regex": "success" },
	    { "title": "Pending", "class": "warning", "regex": "pending" },
	    { "title": "Failed", "class": "important", "regex": "fail" }
	  ],
      "reviewStatuses": [
        { "title": "Looks good!", "class": "success", "regex": "LGTM" },
        { "title": "Please take another look", "class": "info", "regex": "PTAL" },
        { "title": "Comments", "class": "warning", "regex": "comments" }
      ],
      "cookieSecret": "<random>",
      "sessionSecret": "<random>",
      "reviewers": {
        "mark": "mlogan",
        "ian": "statico"
      }
    }

Copyright 2013 Artillery Games, Inc. Licensed under the MIT license.
