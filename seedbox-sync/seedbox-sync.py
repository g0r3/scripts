#!/usr/bin/python
# -*- coding: utf-8 -*-

import requests
import zlib
import sys
import os
import re
import argparse
import traceback
import json
import time
from requests.auth import HTTPBasicAuth
from urllib.parse import quote
from urllib.parse import unquote
from datetime import datetime
from urllib3.exceptions import ReadTimeoutError
from requests.exceptions import ConnectionError

DIR_REGEX = re.compile('<a href=\"(.+)\">(.+)</a>\s+(\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2})\s+([-0-9]+)$')
USERNAME = None
PASSWORD = None
TIMEOUT = 60  # seconds
RETRY_COUNTER = 5
working_directory = None


class IllegalResponseException(Exception):
    pass


class RemoteFile(object):
    '''
    Background: The seedbox http sessions tend to timeout if the download takes too long, which results in corrupted
    files. Therefore split it up and download it using several sessions to prevent timeout within a single session.
    '''
    def __init__(self, username, password, remote_url):
        self.username = username
        self.password = password
        self.remote_url = remote_url
        self.PART_DOWNLOAD_CHUNK_LEN = 1000000000 # bytes
        self.FILE_WRITE_BYTE_COUNT = 8192 # bytes

    def __get_content_length(self):
        r = self.__do_get_request()
        return int(r.headers.get('content-length', 0))

    def __do_get_request(self, startindex=-1, length=0):
        headers = None
        if startindex >= 0 and length >= 1: #partial download requested
            headers = {"Range": "bytes=%s-%s" % (startindex, startindex + length-1)}
        try:
            r = requests.get(url=self.remote_url,
                             stream=True,
                             auth=HTTPBasicAuth(self.username, self.password),
                             headers=headers,
                             timeout=TIMEOUT)
            if r.status_code != 200 and \
               r.status_code != 206:
                raise IllegalResponseException("Status code: %s\n Reason: %s" % (r.status_code, r.reason))
            return r
        except:
            logger(traceback.format_exc())
            raise


    def __partial_file_download(self, local_save_path, startindex, length, force_del=False):
        if not os.path.isfile(local_save_path) or force_del:
            f = open(local_save_path, 'wb')
        else:
            f = open(local_save_path, 'ab')
        response = self.__do_get_request(startindex, length)
        self.__write_responsebody_to_file(f, response)

    def __download_full_file(self, local):
        response = self.__do_get_request()
        f = open(local, 'wb')
        self.__write_responsebody_to_file(f, response)

    def __write_responsebody_to_file(self, file, response):
        written = 0
        for data in response.iter_content(self.FILE_WRITE_BYTE_COUNT):
            file.write(data)
            written += len(data)
            sys.stdout.write("\r%d Bytes downloaded" % written)
            sys.stdout.flush()
        print("")

    def get_remote_hash(self, root):
        logger("Calculating remote hash ...")
        checksum_file_name = "checksum.sfv"

        root_dir = root.rsplit('/')[-1]
        if root_dir == "":
            root_dir = root.rsplit('/')[-2]

        working_dir = unquote(self.remote_url.replace(root, ""))
        working_dir = "/".join([root_dir, working_dir])

        file_to_check = working_dir.rsplit('/', 1)[-1]
        working_dir = working_dir.replace(file_to_check, "")

        file_to_check = unquote(file_to_check)
        working_dir = unquote(working_dir)

        def __do_post_request_with_data(data):
            headers = {"content-type": "application/x-www-form-urlencoded; charset=UTF-8"}
            r = requests.post(url="https://%s.seedbox.io/rutorrent/plugins/filemanager/flm.php" % USERNAME,
                              auth=HTTPBasicAuth(USERNAME, PASSWORD),
                              data=quote(data, safe='=&'),
                              headers=headers,
                              timeout=TIMEOUT)
            return json.loads(r.text)

        def __delete_remote_file():
            data = 'dir=/&action=rm&fls={"0":"%s"}' % checksum_file_name
            response = __do_post_request_with_data(data)
            errcode = response["errcode"]
            if errcode != 0:
                logger("There was a problem when deleting the file /%s" % checksum_file_name)
                raise Exception(response)

        logger("Cleaning up old files...")
        __delete_remote_file()
        data = 'dir=%s&action=sfvcr&target=/%s&fls={"0":"%s"}' % (working_dir, checksum_file_name, file_to_check)
        response = __do_post_request_with_data(data)

        errcode = response["errcode"]
        if errcode != 0:
            logger("There was a problem when deleting the file /%s" % checksum_file_name)
            raise Exception(response)

        target = response["tmpdir"]
        logger("Target is:")
        logger(target)
        status = 0
        fails = 0
        while status == 0:
            data = "dir=/&action=getlog&target=%s" % target
            response = __do_post_request_with_data(data)
            try:
                status = response["status"]
            except KeyError:
                fails += 1
                if fails > 5:
                    logger("Could not retrieve status for checksum file.")
                    logger(data)
                    logger(response)
                    break
            time.sleep(20)

        try:
            hash = response["lines"].split("Hash: ")[1].split("\n")[0].upper()
        except (json.decoder.JSONDecodeError, IndexError, KeyError):
            response = requests.get(url="https://%s.seedbox.io/files/%s" % (USERNAME, checksum_file_name),
                                    stream=True,
                                    auth=HTTPBasicAuth(USERNAME, PASSWORD),
                                    timeout=TIMEOUT)
            hash = response.text.split("\n")[2].rsplit(" ", 1)[-1].upper()

        __delete_remote_file()

        return hash

    def download(self, local_save_path):
        tries = 0

        while True:
            try:
                logger("Starting download of %s" % self.remote_url)
                file_size = self.__get_content_length()

                if file_size <= self.PART_DOWNLOAD_CHUNK_LEN:
                    logger("File is smaller or equal than %s Bytes. Will download it as a whole." % self.PART_DOWNLOAD_CHUNK_LEN)
                    self.__download_full_file(local_save_path)
                    break
                else:
                    logger("File is bigger than %s Bytes. Will download it in sessions." % self.PART_DOWNLOAD_CHUNK_LEN)
                    number_of_chunks = file_size // self.PART_DOWNLOAD_CHUNK_LEN

                    if file_size % self.PART_DOWNLOAD_CHUNK_LEN > 0:
                        number_of_chunks += 1

                    for x in range(0, number_of_chunks):
                        logger("Downloading chunk %s of %s" %(x + 1, number_of_chunks))
                        lower_index = x * self.PART_DOWNLOAD_CHUNK_LEN

                        if (x + 1) == number_of_chunks: # adapt length of last chunk to filesize
                            self.PART_DOWNLOAD_CHUNK_LEN = file_size - lower_index
                        self.__partial_file_download(local_save_path,
                                                     lower_index,
                                                     self.PART_DOWNLOAD_CHUNK_LEN,
                                                     force_del=(x == 0))
                    break
            except (ConnectionError,  ReadTimeoutError, ReadTimeoutError) as e:
                tries += 1
                logger("A exception occured while downloading the file:")
                logger(e)
                if tries >= RETRY_COUNTER:
                    logger("File download unsuccessful. Skipping this file")
                    return 1

        return 0

class PersistantFileList(object):
    '''
    Keeps a list of all the already downloaded torrents, instead of relying on the actual files themselves being
    present locally. The downloaded files can then be moved/deleted. They automatically will be removed from
    the listing once they are not available remotely anymore.
    '''
    def __init__(self, working_directory):

        self.filename = "remotefiles_downloaded"
        self.filelisting = []
        self.new_filelisting = []
        self.path = None

        self.path = os.path.join(working_directory, self.filename)
        if os.path.isfile(self.path):
            file = open(self.path, "r")
            for line in file.read().split("\n"):
                if line.strip() != "":
                    self.filelisting.append(line)
            if len(self.filelisting) == 0:
                #TODO: ADD LOGGING
                pass
        else:
            # TODO: ADD LOGGING
            pass

    def add(self, download):
        self.new_filelisting.append(unquote(download))
        self.save_to_file(keep_old_entries=True)

    def contains(self, download):
        contains = False
        if unquote(download) in self.filelisting:
            self.new_filelisting.append(unquote(download))
            self.filelisting.pop(self.filelisting.index(unquote(download)))
            contains = True
        return contains

    def save_to_file(self, keep_old_entries=False):
        file = open(self.path, "w")
        list = (self.new_filelisting + self.filelisting) if keep_old_entries else self.new_filelisting

        for entry in list:
            file.write(entry + "\n")

def get_dir_listing(url):
    global USERNAME, PASSWORD
    r = requests.get(url, allow_redirects=True, auth=HTTPBasicAuth(USERNAME, PASSWORD), timeout=TIMEOUT)
    dirlisting = []
    for line in r.text.split("\n"):
        line = line.strip("\r")
        if DIR_REGEX.match(line):
            groups = re.search(DIR_REGEX, line)
            file = {"link_text": groups[1],
                    "is_directory": True if groups[4] == "-" else False}
            dirlisting.append(file)
    return dirlisting

def get_local_hash(filename):
    logger("Calculating local hash ...")
    prev = 0
    for eachLine in open(filename,"rb"):
        prev = zlib.crc32(eachLine, prev)
    result = str("%X" % (prev & 0xFFFFFFFF))
    return "0" * (8 - len(result)) + result

def mirror_directory(finished_file_list, from_remote_dir, to_local_dir, root =""):
    global USERNAME, PASSWORD
    dir_listing = get_dir_listing(from_remote_dir)
    for file in dir_listing:
        if file["is_directory"]:
            mirror_directory(finished_file_list=finished_file_list,
                             from_remote_dir=os.path.join(from_remote_dir, file["link_text"]),
                             to_local_dir=to_local_dir,
                             root=from_remote_dir if root == "" else root)
        else:
            remote_file_path = os.path.join(from_remote_dir, file["link_text"])
            if finished_file_list.contains(remote_file_path):
                logger("%s was already downloaded. Skipping." % remote_file_path)
                continue

            # build local save path and do the download
            local_save_path = os.path.normpath(to_local_dir +
                                               unquote(from_remote_dir.replace(from_remote_dir if root == "" else root, "")) +
                                               unquote(file["link_text"]))
            if not os.path.exists(os.path.dirname(local_save_path)):
                os.makedirs(os.path.dirname(local_save_path))
            remote_file = RemoteFile(remote_url=remote_file_path, username=USERNAME, password=PASSWORD)

            if remote_file.download(local_save_path) == 1:
                # file download was not successful. Hence skip out of this iteration
                continue
            logger("Download finished")

            # Check file integrity
            remote_hash = remote_file.get_remote_hash(from_remote_dir if root == "" else root)
            logger("Hash of remote file is %s" % remote_hash)
            local_hash = get_local_hash(local_save_path)
            logger("Hash of local file is %s" % local_hash)
            if (local_hash != remote_hash):
                logger("Hashes do not match. Will redownload file during the next run")
                continue
            logger("Hashes match. Proceeding with next file")

            # if everything was ok add the file to the list off successfully downloaded files
            finished_file_list.add(remote_file_path)

def logger(message):
    global working_directory

    timestamp = "[" + datetime.strftime(datetime.now(), "%Y/%m/%d-%H:%M:%S.%f] - ")
    file = open(os.path.join(working_directory, "log"), "a+")
    for line in str(message).split("\n"):
        logline = timestamp + line
        print(logline)
        file.write(logline + "\n")

def set_lockfile(working_directory):
    lockfile = os.path.join(working_directory, "lockfile")

    if os.path.isfile(lockfile):
        logger("Lockfile already exists. Exiting")
        quit(0)
    open(lockfile, "w+")


def remove_lockfile(working_directory):
    lockfile = os.path.join(working_directory, "lockfile")

    if os.path.isfile(lockfile):
        os.remove(lockfile)

def main(args):
    global USERNAME, PASSWORD, working_directory

    USERNAME = args.user
    PASSWORD = args.password

    working_directory = os.path.abspath(args.ldir) if args.wdir == None else args.wdir
    working_directory = os.path.abspath(working_directory)

    # setup logfile
    try:
        if not os.path.exists(working_directory):
            os.makedirs(working_directory)
        if not os.path.isfile(os.path.join(working_directory, "log")):
            open(os.path.join(working_directory, "log"), "w").close()
    except:
        logger("Could not create logfile. Exiting...")
        logger(traceback.format_exc())
        os._exit(1)

    # check if remote exists and credentials are correct
    url = args.url + "/" if not args.url.endswith("/") else args.url
    r = requests.get(url, auth=HTTPBasicAuth(USERNAME, PASSWORD), timeout=TIMEOUT)
    if r.status_code != 200:
        logger("Could not retrieve remote ressource. Response was:")
        logger(r.status_code)
        logger(r.text)
        os._exit(1)
        
    # setup local target dir
    ldir = os.path.abspath(args.ldir)
    ldir = ldir + "/" if not ldir.endswith("/") else ldir


    # start downloading
    set_lockfile(working_directory)
    try:
        persistant_file_list = PersistantFileList(working_directory)
        mirror_directory(persistant_file_list, args.url, ldir)
        # at this point all left over downloads in the list are not present anymore on the server. So delete them
        persistant_file_list.save_to_file(keep_old_entries=False)
    except (KeyboardInterrupt, SystemExit):
        remove_lockfile(working_directory)
        os._exit(1)
    except:
        logger(traceback.format_exc())

    remove_lockfile(working_directory)



if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sync remote http directory to a local directory.")
    parser.add_argument("--url", type=str, help="The target server", required=True)
    parser.add_argument("--user", type=str, help="Username for the account", required=True)
    parser.add_argument("--password", type=str, help="Password for the account", required=True)
    parser.add_argument("--ldir", type=str, help="Local directory for syncing to", required=True)
    parser.add_argument("--wdir", type=str, help="Working directory. Default: same as --ldir")
    args = parser.parse_args()
    main(args)