---
layout: post
title:  "In to the jungle"
slug: in-to-the-jungle
date:   2018-02-11 00:03:20 +1200
categories: jekyll update
---
1. learn Jenkins
    java -jar jenkins.war
    init jenkins, user.password
    create pipelinefile to own github repo
    create jenkins_test with example code
    mv jenkinsFile
    mv jenkinsFile /jenkinsFile
2. Things went bad
    Docker failed to start
    - something related to virtual hdd
      - mainly Hyper-V feature
      - [from Google, SO]
        - cause Windows permission issue
          - solve change folder to d: //drive for dev.
        - cause experimental feature
          - solve turn it off
    reset system/host Windows
    Docker came back to life
3. Come back to jenkins
    Jenkins can access to Agent now
    nohup not found
      - add {Git}/bin to Windows's PATH
      - mklink {Git}/usr/bin/nohup.exe {Git}/bin/nohup.exe
        //with others essential dll
      - don't forget to reset Jenkins (since powershell/cmd does not refresh PATH automatically)
    set Jenkins shell to win32/cmd
      - seems didn't work
4. Install Jenkins as Windows service
    requires new init, no problem


5. Install Jekyll locally on Windows
  - cause no 'make' program
  - got make from sourceforge https://gist.github.com/evanwill/0207876c3243bbb6863e65ec5dc3f058
  - still fail due to some path problem
  | solved at 8. wrong 'make' obstruct commonmarker installation.
6. Install Windows Subsystem for Linux
  - Got Ubuntu 14.04 from Windows store https://docs.microsoft.com/en-us/windows/wsl/install-win10
  - Follows https://jekyllrb.com/docs/windows/#installation
  - good so far until 'bundle install', some lib was not found, apt-get, solved
  - Too slow to make a productive
  - cannot solve nokogori installation stalled
7. Try jekyll docker
  - Docker Linux container failed
    - Work around not so good, best be is clear as much startup process
    - switch Windows/Linux container doesn't work, restart Windows
    - some clue about 60s init timeout https://github.com/docker/for-win/issues/447#issuecomment-277730926
  - Docker work, but cobble some with jekyll process
  - stuck at installing...nokogiri...forever
8. Official GitHub guide to create page
   - https://pages.github.com/
9. Come back to native Ruby 2.4 installation
    found that the "make" should already included in Ruby Devkit...
    - went back to run [ridk install] for MSYS2-DEVKIT
    - succeed install commonmarker
