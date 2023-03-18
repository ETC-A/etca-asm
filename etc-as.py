#!/usr/bin/env python3.10
import sys

if sys.version_info[0:2] < (3, 10):
    print('Python 3.10 or newer is required to run this')
    exit(code=1)

from etc_as.main import main

if __name__ == '__main__':
    main()
