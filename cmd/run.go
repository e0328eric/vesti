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
	sigs := make(chan os.Signal, 1)
	outputFileName := strings.TrimSuffix(args[0], filepath.Ext(args[0])) + ".tex"
	initCompile := true

	// Make a file if it is not exist
	outFile, err := os.Create(outputFileName)
	checkIsPanic(err)

	// Take a modification time
	initData, err := os.Stat(args[0])
	checkIsPanic(err)
	initTime := initData.ModTime()
	nowTime := initTime

	// Exit properly if these signal is appear, respectively.
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGKILL)

	if vestiContinuousCompile {
		go func() {
			<-sigs
			err = outFile.Close()
			checkIsPanic(err)
			fmt.Println("bye!")
			os.Exit(0)
		}()
	}

	// This for loop is mimicked of do-while loop in C relative language
	for {
		if initCompile || initTime != nowTime {
			// Read a file
			input, err := ioutil.ReadFile(args[0])
			checkIsPanic(err)

			// Critical part: compiling vesti
			l := lexer.New(string(input))
			p := parser.New(l)
			output, vError := p.MakeLatexFormat()
			if vError != nil {
				fmt.Println(verror.PrintErr(string(input), &args[0], vError))
				os.Exit(1)
			}

			// Write or make a output tex file
			err = outFile.Truncate(0)
			checkIsPanic(err)
			_, err = outFile.Seek(0, 0)
			checkIsPanic(err)
			_, err = outFile.WriteString(output)
			checkIsPanic(err)

			initCompile = false
			initTime = nowTime
			fmt.Print("Press Ctrl+C to quit vesti\n")
		}

		if !vestiContinuousCompile {
			err = outFile.Close()
			checkIsPanic(err)
			fmt.Println("bye!")
			break
		}

		// Keep tracking modification input time so that determine whether vesti is run
		nowData, err := os.Stat(args[0])
		checkIsPanic(err)
		nowTime = nowData.ModTime()
		time.Sleep(500 * time.Millisecond)
	}
}
