/*
Copyright © 2021 Sungbae Jeong <almagest0328@gmail.com>
*/
package cmd

import (
	"fmt"
	"io/ioutil"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"vesti/lexer"
	"vesti/parser"
	verror "vesti/vestiError"

	"github.com/spf13/cobra"
)

// runCmd represents the run command
var runCmd = &cobra.Command{
	Use:   "run",
	Short: "Compile vesti language",
	Long:  ``,
	Args:  cobra.MinimumNArgs(1),
	Run:   runVesti,
}

var vestiContinuousCompile = false

func init() {
	rootCmd.AddCommand(runCmd)

	// Continuous compiling flag
	runCmd.Flags().BoolVarP(
		&vestiContinuousCompile,
		"continuous",
		"c",
		false,
		"Compile vesti continuously. Quit the program pressing Ctrl+C",
	)
}

func checkIsPanic(err error) {
	if err != nil {
		panic(err)
	}
}

func runVesti(_ *cobra.Command, args []string) {
	// Define essential new variables
	var wg sync.WaitGroup
	var outFileList []*os.File
	sigs := make(chan os.Signal, 1)

	// Exit properly if these signal is appear, respectively.
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGKILL)

	if vestiContinuousCompile {
		go func() {
			<-sigs
			for _, file := range outFileList {
				err := file.Close()
				checkIsPanic(err)
			}
			os.Exit(0)
		}()
	}

	// This for loop is mimicked of do-while loop in C relative language
	for _, source := range args {
		outputFileName := strings.TrimSuffix(source, filepath.Ext(args[0])) + ".tex"

		// Make a file if it is not exist
		outFile, err := os.Create(outputFileName)
		checkIsPanic(err)
		outFileList = append(outFileList, outFile)

		wg.Add(1)
		go compileVesti(outFile, source, &wg)
	}

	fmt.Print("Press Ctrl+C to quit vesti\n")
	wg.Wait()
	fmt.Println("bye!")
}

func compileVesti(
	outFile *os.File,
	source string,
	wg *sync.WaitGroup,
) {
	// Take a modification time
	initData, err := os.Stat(source)
	checkIsPanic(err)
	initTime := initData.ModTime()
	nowTime := initTime

	// Switch init compile state
	initCompile := true

	for {
		if initCompile || initTime != nowTime {
			// Read a file
			input, err := ioutil.ReadFile(source)
			checkIsPanic(err)

			// Critical part: compiling vesti
			l := lexer.New(string(input))
			p := parser.New(l)
			output, vError := p.MakeLatexFormat()
			if vError != nil {
				fmt.Println(verror.PrintErr(string(input), &source, vError))
				os.Exit(1)
			}

			// Write or make a output tex file
			err = outFile.Truncate(0)
			checkIsPanic(err)
			_, err = outFile.Seek(0, 0)
			checkIsPanic(err)
			_, err = outFile.WriteString(output)
			checkIsPanic(err)

			if !initCompile {
				fmt.Print("Press Ctrl+C to quit vesti\n")
			}
			initCompile = false
			initTime = nowTime
		}

		if !vestiContinuousCompile {
			err := outFile.Close()
			checkIsPanic(err)
			break
		}

		// Keep tracking modification input time so that determine whether vesti is run
		nowData, err := os.Stat(source)
		checkIsPanic(err)
		nowTime = nowData.ModTime()
		time.Sleep(500 * time.Millisecond)
	}

	wg.Done()
}
